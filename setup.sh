#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DIR
GENERATED_DIR="$HOME/.server-configs-generated"
readonly GENERATED_DIR
INSTALL_MANIFEST="$GENERATED_DIR/install-manifest.txt"
readonly INSTALL_MANIFEST
CLAUDE_SETTINGS_SRC=""
CLAUDE_SETTINGS_MODE="repo"
CODEX_CONFIG_SRC=""
CODEX_CONFIG_MODE="repo"
reset_module_vars() {
    local module_var

    for module_var in NVIM_MODULE CLAUDE_MODULE CODEX_MODULE GH_MODULE NODE_MODULE UV_MODULE BTOP_MODULE; do
        printf -v "$module_var" '%s' ""
    done
}

reset_module_vars
# CHPC module names — verified against `module spider` on notchpeak2
# (2026-05). Re-verify with: ./setup.sh --probe-modules
CLAUDE_MODULE_CANDIDATES=("claude")
CODEX_MODULE_CANDIDATES=("codex")
GH_MODULE_CANDIDATES=("gh")
NODE_MODULE_CANDIDATES=("nodejs")
UV_MODULE_CANDIDATES=("uv")
BTOP_MODULE_CANDIDATES=("btop")
NVIM_MODULE_CANDIDATES=("nvim/0.11.2" "nvim")
# tree-sitter has no CHPC module today; install_tree_sitter falls back to
# the prebuilt binary (then to cargo build-from-source if glibc is too old).
TREE_SITTER_MODULE_CANDIDATES=()
FORCE="${FORCE:-false}"
DRY_RUN="${DRY_RUN:-false}"
CHPC_USE_MODULES="${CHPC_USE_MODULES:-false}"
FAILURES=()

_setup_cleanup() {
    [ -n "${_GH_LATEST_CACHE_FILE:-}" ] && rm -f "$_GH_LATEST_CACHE_FILE" 2>/dev/null
}

# --- Shared helpers (run_step, retry, backup_and_link, backup_and_copy) ---
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

# --- Helpers ---

# Wrapper: move/copy files respecting sudo needs
install_to() {
    local src="$1" dst="$2"
    if [ "${DRY_RUN:-false}" = true ]; then
        echo "[dry-run] Would install $src -> $dst"
        return 0
    fi
    if [ -n "$NEED_SUDO" ]; then
        sudo mv -f "$src" "$dst"
    else
        mv -f "$src" "$dst"
    fi
}

command_output_contains() {
    local pattern="$1"
    local output
    shift
    output="$("$@" 2>/dev/null || true)"
    [[ "$output" == *"$pattern"* ]]
}

record_command_if_managed() {
    local cmd="$1"
    local path

    path="$(command -v "$cmd" 2>/dev/null || true)"
    [ -n "$path" ] || return 1
    case "$path" in
        "$HOME"/*) ;;
        *) return 0 ;;
    esac
    manifest_add_path "$path"
}

brew_install() {
    local formula="$1" cmd="${2:-$1}"

    is_macos || return 1
    if ! command -v brew &>/dev/null; then
        echo "  Skipping $formula: Homebrew is not installed."
        return 1
    fi
    if command -v "$cmd" &>/dev/null && ! $FORCE; then
        echo "$cmd already installed: $("$cmd" --version 2>&1 | head -1)"
        return 0
    fi
    echo "Installing $formula with Homebrew..."
    if brew list --formula "$formula" >/dev/null 2>&1 && ! $FORCE; then
        brew link "$formula" >/dev/null 2>&1 || true
    else
        brew install "$formula" || return 1
    fi
    hash -r
    command -v "$cmd" &>/dev/null
}

record_node_manifest() {
    local path

    for path in \
        "$HOME/.local/bin/node" \
        "$HOME/.local/bin/npm" \
        "$HOME/.local/bin/npx" \
        "$HOME/.local/bin/corepack" \
        "$HOME/.local/lib/node_modules" \
        "$HOME/.local/include/node" \
        "$HOME/.local/share/doc/node" \
        "$HOME/.local/share/man/man1/node.1" \
        "$HOME/.local/share/systemtap/tapset/node.stp"
    do
        [ -e "$path" ] && manifest_add_path "$path"
    done
}

record_nvim_manifest() {
    local opt_dir target target_bin expected

    target_bin="$HOME/.local/bin/nvim"
    opt_dir="$HOME/.local/opt/nvim"

    if [ -L "$target_bin" ]; then
        target="$(portable_realpath "$target_bin" 2>/dev/null || true)"
        # Resolve the expected path the same way so parent-dir symlinks
        # (e.g. macOS /var -> /private/var inside mktemp roots) don't
        # cause a spurious mismatch.
        expected="$(portable_realpath "$opt_dir/bin/nvim" 2>/dev/null || printf '%s' "$opt_dir/bin/nvim")"
        [ "$target" = "$expected" ] || return 0
        manifest_add_path "$target_bin"
        [ -d "$opt_dir" ] && manifest_add_path "$opt_dir"
    fi
}

append_line_if_missing() {
    local line="$1" file="$2"

    if ! grep -qF "$line" "$file" 2>/dev/null; then
        mkdir -p "$(dirname "$file")" || return 1
        printf '%s\n' "$line" >> "$file" || return 1
    fi
}

version_at_least() {
    local actual="$1" required="$2"
    awk -v actual="$actual" -v required="$required" '
        function split_version(version, parts, count, i) {
            count = split(version, parts, ".")
            for (i = count + 1; i <= 4; i++) {
                parts[i] = 0
            }
            return count
        }
        BEGIN {
            split_version(actual, actual_parts)
            split_version(required, required_parts)
            for (i = 1; i <= 4; i++) {
                if ((actual_parts[i] + 0) > (required_parts[i] + 0)) exit 0
                if ((actual_parts[i] + 0) < (required_parts[i] + 0)) exit 1
            }
            exit 0
        }
    '
}

tmux_version() {
    command -v tmux &>/dev/null || return 1
    tmux -V 2>/dev/null | awk '{print $2}' | sed 's/[^0-9.].*$//'
}

tmux_default_terminal() {
    if command -v infocmp &>/dev/null && infocmp tmux-256color &>/dev/null; then
        echo "tmux-256color"
    else
        echo "screen-256color"
    fi
}

tmux_supports_allow_passthrough() {
    local version
    version="$(tmux_version 2>/dev/null || true)"
    [ -n "$version" ] && version_at_least "$version" "3.3"
}

tmux_supports_set_clipboard() {
    local version
    version="$(tmux_version 2>/dev/null || true)"
    [ -n "$version" ] && version_at_least "$version" "2.6"
}

vim_supports_clipboard() {
    command -v vim &>/dev/null || return 1
    vim --version 2>/dev/null | grep -Eq '^\+(clipboard|xterm_clipboard)\b'
}

vim_supports_unicode_listchars() {
    command -v vim &>/dev/null || return 1
    vim -Nu NONE -n -es +'set listchars=tab:>>·,trail:·,extends:›,precedes:‹,nbsp:␣' +qall! >/dev/null 2>&1
}

gh_supports_git_credential() {
    command -v gh &>/dev/null || return 1
    gh auth git-credential --help >/dev/null 2>&1
}

claude_supports_settings() {
    command -v claude &>/dev/null || return 1
    command_output_contains '--settings ' claude --help
}

claude_supports_permission_mode() {
    command -v claude &>/dev/null || return 1
    command_output_contains '--permission-mode ' claude --help
}

claude_supports_mcp() {
    command -v claude &>/dev/null || return 1
    claude mcp --help >/dev/null 2>&1
}

claude_supports_plugins() {
    command -v claude &>/dev/null || return 1
    claude plugin --help >/dev/null 2>&1 || claude plugins --help >/dev/null 2>&1
}

claude_supports_plugin_marketplace() {
    command -v claude &>/dev/null || return 1
    claude plugin marketplace --help >/dev/null 2>&1 || claude plugins marketplace --help >/dev/null 2>&1
}

codex_supports_settings() {
    command -v codex &>/dev/null || return 1
    command_output_contains '--ask-for-approval' codex --help &&
        command_output_contains '--sandbox' codex --help
}

codex_supports_login_status() {
    command -v codex &>/dev/null || return 1
    codex login --help 2>/dev/null | grep -q '^[[:space:]]*status[[:space:]]'
}

ensure_module_command() {
    local init

    if command -v module &>/dev/null; then
        return 0
    fi

    for init in /etc/profile.d/modules.sh /etc/profile.d/lmod.sh /usr/share/Modules/init/bash; do
        if [ -r "$init" ]; then
            # shellcheck disable=SC1090
            . "$init" >/dev/null 2>&1 || true
            if command -v module &>/dev/null; then
                return 0
            fi
        fi
    done

    return 1
}

# Try to satisfy a tool requirement on CHPC via environment modules.
# Sets the named variable to the loaded module name on success.
# Returns 0 if already available or loaded; 1 if no module found.
try_chpc_module_load() {
    local cmd="$1" display="$2" var_name="$3"
    shift 3
    local tried=("$@")

    if ensure_module_command; then
        local mod
        for mod in "$@"; do
            if module load "$mod" 2>/dev/null && command -v "$cmd" &>/dev/null; then
                hash -r
                printf -v "$var_name" '%s' "$mod"
                echo "$display loaded via module: $mod ($("$cmd" --version 2>&1 | head -1))"
                return 0
            fi
        done
    fi
    if command -v "$cmd" &>/dev/null && ! $FORCE; then
        echo "$display already available: $("$cmd" --version 2>&1 | head -1)"
        return 0
    fi
    echo "  Warning: no $display module found on CHPC — skipping self-install"
    if [ "${#tried[@]}" -gt 0 ]; then
        echo "  Tried: ${tried[*]}"
    fi
    echo "  Check available modules with: module spider $cmd"
    return 1
}

# Print which CHPC module candidates resolve and which don't, without
# loading anything. Useful for re-verifying the candidate lists after
# CHPC adds, removes, or renames modules.
probe_chpc_modules() {
    if ! ensure_module_command; then
        echo "Error: 'module' command unavailable. Run this on a CHPC login/compute node."
        return 1
    fi
    local group candidates_var name resolved out
    local groups=(
        "Claude Code:CLAUDE_MODULE_CANDIDATES"
        "Codex:CODEX_MODULE_CANDIDATES"
        "GitHub CLI:GH_MODULE_CANDIDATES"
        "Node.js:NODE_MODULE_CANDIDATES"
        "uv:UV_MODULE_CANDIDATES"
        "btop:BTOP_MODULE_CANDIDATES"
        "Neovim:NVIM_MODULE_CANDIDATES"
        "tree-sitter:TREE_SITTER_MODULE_CANDIDATES"
    )
    printf '%-14s %-12s %s\n' "TOOL" "STATUS" "CANDIDATE"
    printf '%-14s %-12s %s\n' "----" "------" "---------"
    for group in "${groups[@]}"; do
        name="${group%%:*}"
        candidates_var="${group##*:}"
        local -n arr="$candidates_var"
        if [ "${#arr[@]}" -eq 0 ]; then
            printf '%-14s %-12s %s\n' "$name" "(none)" "no candidates configured"
            continue
        fi
        for cand in "${arr[@]}"; do
            out="$(module spider "$cand" 2>&1)"
            if printf '%s' "$out" | grep -q 'Unable to find'; then
                printf '%-14s %-12s %s\n' "$name" "MISSING" "$cand"
            else
                # Prefer (D)-marked default, else last version Lmod prints.
                resolved="$(printf '%s\n' "$out" | awk -v cand="$cand" '
                    $0 ~ "^  " cand ": " cand "/" {
                        if (match($0, cand "/[^[:space:]]+") > 0) {
                            print substr($0, RSTART, RLENGTH); exit
                        }
                    }
                    $0 ~ "^[ ]+" cand "/[0-9]" {
                        if (match($0, cand "/[^[:space:](]+") > 0) {
                            v = substr($0, RSTART, RLENGTH)
                            if (index($0, "(D)") > 0) { print v; exit }
                            last = v
                        }
                    }
                    END { if (last != "") print last }
                ')"
                printf '%-14s %-12s %s\n' "$name" "FOUND" "$cand${resolved:+ -> $resolved}"
            fi
        done
    done
}

render_tmux_compat() {
    local default_terminal
    default_terminal="$(tmux_default_terminal)"

    cat > "$GENERATED_DIR/tmux.compat.conf" <<EOF
# Generated by setup.sh. Re-run setup.sh after changing tmux versions.
set -g default-terminal "${default_terminal}"
set -ga terminal-overrides ",xterm-256color:Tc"
EOF

    if tmux_supports_allow_passthrough; then
        cat >> "$GENERATED_DIR/tmux.compat.conf" <<'EOF'
set -g allow-passthrough on
EOF
    else
        cat >> "$GENERATED_DIR/tmux.compat.conf" <<'EOF'
# tmux < 3.3: leave passthrough disabled to avoid startup errors.
EOF
    fi

    if tmux_supports_set_clipboard; then
        cat >> "$GENERATED_DIR/tmux.compat.conf" <<'EOF'
set -s set-clipboard on
EOF
    else
        cat >> "$GENERATED_DIR/tmux.compat.conf" <<'EOF'
# tmux clipboard integration unavailable on this host version.
EOF
    fi
}

render_vim_compat() {
    local listchars

    if vim_supports_unicode_listchars; then
        listchars='tab:>>·,trail:·,extends:›,precedes:‹,nbsp:␣'
    else
        listchars='tab:>-,trail:.,extends:>,precedes:<,nbsp:+'
    fi

    cat > "$GENERATED_DIR/vimrc.compat" <<EOF
" Generated by setup.sh. Re-run setup.sh after changing Vim versions.
set listchars=${listchars}
EOF

    if vim_supports_clipboard; then
        cat >> "$GENERATED_DIR/vimrc.compat" <<'EOF'
set clipboard=unnamedplus
EOF
    else
        cat >> "$GENERATED_DIR/vimrc.compat" <<'EOF'
" Clipboard support not available in this Vim build.
EOF
    fi

    cat >> "$GENERATED_DIR/vimrc.compat" <<'EOF'
if has('nvim')
    augroup server_configs_compat
        autocmd!
        autocmd TextYankPost * silent! lua vim.highlight.on_yank()
    augroup END
endif
EOF
}

render_git_compat() {
    if gh_supports_git_credential; then
        cat > "$GENERATED_DIR/gitconfig.compat" <<'EOF'
[credential "https://github.com"]
	helper =
	helper = !gh auth git-credential

[credential "https://gist.github.com"]
	helper =
	helper = !gh auth git-credential
EOF
    else
        cat > "$GENERATED_DIR/gitconfig.compat" <<'EOF'
# Generated by setup.sh. GitHub CLI credential helper unavailable on this host.
EOF
    fi
}

render_bash_compat() {
    cat > "$GENERATED_DIR/bashrc_compat" <<'EOF'
# Generated by setup.sh. Re-run setup.sh after upgrading Claude Code or Codex CLI.
if [ -n "${SERVER_CONFIGS_BASH_COMPAT_LOADED:-}" ]; then
    return 0
fi
SERVER_CONFIGS_BASH_COMPAT_LOADED=1
EOF

    # Persist module loads for any tool installed via module. We only run
    # them in interactive shells: SLURM job-step shells (srun --pty bash)
    # inherit Lmod state from the job, and an unconditional `module load`
    # here can swap MPI/compiler combos and break job startup.
    local mod_load mod_val _any_module=false
    for mod_load in NVIM_MODULE CLAUDE_MODULE CODEX_MODULE GH_MODULE NODE_MODULE UV_MODULE BTOP_MODULE; do
        mod_val="${!mod_load:-}"
        if [ -n "$mod_val" ]; then
            if ! "$_any_module"; then
                _any_module=true
                cat >> "$GENERATED_DIR/bashrc_compat" <<'EOF'

# Environment modules — interactive shells only.
case $- in
    *i*) ;;
    *) return 0 ;;
esac
if ! command -v module &>/dev/null; then
    for init in /etc/profile.d/modules.sh /etc/profile.d/lmod.sh /usr/share/Modules/init/bash; do
        if [ -r "$init" ]; then
            . "$init" >/dev/null 2>&1 && break
        fi
    done
fi
_server_configs_module_load() {
    command -v module &>/dev/null || return 0
    module load "$@"
}
EOF
            fi
            cat >> "$GENERATED_DIR/bashrc_compat" <<EOF
_server_configs_module_load ${mod_val}
EOF
        fi
    done
}

render_claude_settings_target() {
    CLAUDE_SETTINGS_SRC="$DIR/claude_settings.json"
    CLAUDE_SETTINGS_MODE="repo"

    if ! command -v claude &>/dev/null; then
        return 0
    fi

    if claude_supports_settings && claude_supports_permission_mode; then
        rm -f "$GENERATED_DIR/claude_settings.json"
        return 0
    fi

    cat > "$GENERATED_DIR/claude_settings.json" <<'EOF'
{}
EOF
    CLAUDE_SETTINGS_SRC="$GENERATED_DIR/claude_settings.json"
    CLAUDE_SETTINGS_MODE="fallback"
}

render_codex_config_target() {
    CODEX_CONFIG_SRC="$DIR/codex_config.toml"
    CODEX_CONFIG_MODE="repo"

    if ! command -v codex &>/dev/null; then
        return 0
    fi

    if codex_supports_settings; then
        rm -f "$GENERATED_DIR/codex_config.toml"
        return 0
    fi

    cat > "$GENERATED_DIR/codex_config.toml" <<'EOF'
# Generated by setup.sh for an older Codex CLI.
EOF
    CODEX_CONFIG_SRC="$GENERATED_DIR/codex_config.toml"
    CODEX_CONFIG_MODE="fallback"
}

write_compat_report() {
    local tmux_version_out="not installed"
    local tmux_default_term
    local tmux_passthrough="off"
    local vim_version_out="not installed"
    local vim_clipboard="off"
    local vim_listchars_mode="ascii"
    local gh_helper="off"
    local nvim_version_out="not installed"
    local claude_version_out="not installed"
    local codex_version_out="not installed"
    local chpc_out="no"
    local generated_at

    generated_at="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    is_chpc && chpc_out="yes"
    tmux_default_term="$(tmux_default_terminal)"

    if command -v tmux &>/dev/null; then
        tmux_version_out="$(tmux -V 2>/dev/null)"
        tmux_supports_allow_passthrough && tmux_passthrough="on"
    fi

    if command -v vim &>/dev/null; then
        vim_version_out="$(vim --version 2>/dev/null | head -1)"
        vim_supports_clipboard && vim_clipboard="on"
        if vim_supports_unicode_listchars; then
            vim_listchars_mode="unicode"
        fi
    fi

    gh_supports_git_credential && gh_helper="on"

    if command -v nvim &>/dev/null; then
        nvim_version_out="$(nvim --version 2>/dev/null | head -1)"
    fi

    if command -v claude &>/dev/null; then
        claude_version_out="$(claude --version 2>&1 | head -1)"
    fi

    local starship_version_out="not installed"
    local atuin_version_out="not installed"

    if command -v starship &>/dev/null; then
        starship_version_out="$(starship --version 2>&1 | head -1)"
    fi

    if command -v atuin &>/dev/null; then
        atuin_version_out="$(atuin --version 2>&1 | head -1)"
    fi

    if command -v codex &>/dev/null; then
        codex_version_out="$(codex --version 2>&1 | head -1)"
    fi

    cat > "$GENERATED_DIR/compat-report.txt" <<EOF
server-configs compatibility report
Generated: ${generated_at}
chpc: ${chpc_out}

tmux: ${tmux_version_out}
  default-terminal: ${tmux_default_term}
  allow-passthrough: ${tmux_passthrough}

vim: ${vim_version_out}
  clipboard: ${vim_clipboard}
  listchars: ${vim_listchars_mode}

nvim: ${nvim_version_out}

git:
  gh git-credential helper: ${gh_helper}

starship: ${starship_version_out}
atuin: ${atuin_version_out}

claude: ${claude_version_out}
  settings source: ${CLAUDE_SETTINGS_MODE}

codex: ${codex_version_out}
  settings source: ${CODEX_CONFIG_MODE}
  login status command: $(codex_supports_login_status && echo on || echo off)
EOF
}

render_compat_configs() {
    render_tmux_compat
    render_vim_compat
    render_git_compat
    render_bash_compat
    render_claude_settings_target
    render_codex_config_target
    write_compat_report
}

# Latest release version from GitHub (strips leading 'v'). API first;
# falls back to the HTML redirect parse when no JSON parser is available.
# File-based cache because every caller uses $(gh_latest …), and a
# `declare -gA` in-shell cache wouldn't survive the subshell.
_GH_LATEST_CACHE_FILE="${_GH_LATEST_CACHE_FILE:-${TMPDIR:-/tmp}/.gh-latest-cache.$$}"

gh_latest() {
    local slug="$1" version="" s v
    if [ -f "$_GH_LATEST_CACHE_FILE" ]; then
        while IFS=$'\t' read -r s v; do
            if [ "$s" = "$slug" ]; then
                printf '%s\n' "$v"
                return 0
            fi
        done < "$_GH_LATEST_CACHE_FILE"
    fi

    # Scoped pipefail so a curl-200-but-jq-fail (GitHub rate-limit HTML)
    # surfaces as a failure instead of an empty $version slipping through.
    local -
    set -o pipefail

    if command -v jq &>/dev/null; then
        version="$(retry curl -sfL "https://api.github.com/repos/$slug/releases/latest" 2>/dev/null \
            | jq -r '.tag_name // empty' 2>/dev/null \
            | sed 's/^v//')" || version=""
    elif command -v python3 &>/dev/null; then
        version="$(retry curl -sfL "https://api.github.com/repos/$slug/releases/latest" 2>/dev/null \
            | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('tag_name','').lstrip('v'))
except Exception:
    pass" 2>/dev/null)" || version=""
    fi

    if [ -z "$version" ]; then
        version="$(retry curl -sfI "https://github.com/$slug/releases/latest" \
            | grep -i '^location:' | sed 's|.*/v\?\([^/[:space:]]*\).*|\1|')" || version=""
    fi

    if [ -z "$version" ]; then
        echo "  Warning: could not determine latest version for $slug" >&2
        return 1
    fi
    printf '%s\t%s\n' "$slug" "$version" >> "$_GH_LATEST_CACHE_FILE" 2>/dev/null || true
    printf '%s\n' "$version"
}

# Install a binary from a GitHub release tarball
install_gh_binary() {
    local name="$1" url="$2" bin_name="${3:-$1}"
    if command -v "$bin_name" &>/dev/null && ! $FORCE; then
        record_command_if_managed "$bin_name" || true
        echo "$bin_name already installed"
        return 0
    fi
    echo "Installing $name..."
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/archive" "$url"; then
        echo "  Warning: failed to download $name"
        return 1
    fi
    case "$url" in
        *.tbz|*.tar.bz2) tar xj -C "$TMP" -f "$TMP/archive" ;;
        *)                tar xz -C "$TMP" -f "$TMP/archive" ;;
    esac
    local bin
    bin="$(find "$TMP" -type f -name "$bin_name" | head -1)"
    if [ -z "$bin" ]; then
        echo "  Warning: $bin_name binary not found in archive"
        return 1
    fi
    chmod +x "$bin"
    if ! install_to "$bin" "$BIN_DIR/$bin_name"; then
        echo "  Warning: failed to install $name to $BIN_DIR/$bin_name"
        return 1
    fi
    manifest_add_path "$BIN_DIR/$bin_name"
    echo "  $name installed to $BIN_DIR/$bin_name"
}

# Install a bare binary (no archive) from a GitHub release
install_gh_bare_binary() {
    local name="$1" url="$2" bin_name="${3:-$1}"
    if command -v "$bin_name" &>/dev/null && ! $FORCE; then
        record_command_if_managed "$bin_name" || true
        echo "$bin_name already installed"
        return 0
    fi
    echo "Installing $name..."
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/$bin_name" "$url"; then
        echo "  Warning: failed to download $name"
        return 1
    fi
    chmod +x "$TMP/$bin_name"
    if ! install_to "$TMP/$bin_name" "$BIN_DIR/$bin_name"; then
        echo "  Warning: failed to install $name to $BIN_DIR/$bin_name"
        return 1
    fi
    manifest_add_path "$BIN_DIR/$bin_name"
    echo "  $name installed to $BIN_DIR/$bin_name"
}

# --- Install functions ---

install_gh_cli() {
    if is_macos; then
        brew_install gh gh
        return $?
    fi
    if is_chpc && $CHPC_USE_MODULES; then
        try_chpc_module_load gh "GitHub CLI" GH_MODULE "${GH_MODULE_CANDIDATES[@]}"
        return
    fi
    if command -v gh &>/dev/null && ! $FORCE; then
        record_command_if_managed gh || true
        echo "gh already installed: $(gh --version | head -1)"
        return 0
    fi
    echo "Installing GitHub CLI..."
    local GH_VERSION
    GH_VERSION="$(gh_latest cli/cli)" || return 1
    local ARCH GH_ARCH
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  GH_ARCH="amd64" ;;
        aarch64) GH_ARCH="arm64" ;;
        *)       echo "  Skipping gh (unsupported arch: $ARCH)"; return 1 ;;
    esac
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/archive.tar.gz" "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${GH_ARCH}.tar.gz"; then
        echo "  Warning: failed to download gh"
        return 1
    fi
    tar xz -C "$TMP" -f "$TMP/archive.tar.gz"
    local bin
    bin="$(find "$TMP" -type f -name "gh" -path '*/bin/*' | head -1)"
    if [ -z "$bin" ]; then
        echo "  Warning: gh binary not found in archive"
        return 1
    fi
    chmod +x "$bin"
    if ! install_to "$bin" "$BIN_DIR/gh"; then
        echo "  Warning: failed to install gh to $BIN_DIR/gh"
        return 1
    fi
    manifest_add_path "$BIN_DIR/gh"
    echo "  gh $GH_VERSION installed to $BIN_DIR/gh"
    if ! gh auth status &>/dev/null; then
        echo "  Run 'gh auth login' to authenticate with GitHub."
    fi
}

install_glow() {
    if is_macos; then
        brew_install glow glow
        return $?
    fi
    if command -v glow &>/dev/null && ! $FORCE; then
        record_command_if_managed glow || true
        echo "glow already installed: $(glow --version)"
        return 0
    fi
    echo "Installing glow..."
    local GLOW_VERSION
    GLOW_VERSION="$(gh_latest charmbracelet/glow)" || return 1
    local ARCH GLOW_ARCH
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  GLOW_ARCH="x86_64" ;;
        aarch64) GLOW_ARCH="arm64"  ;;
        *)       echo "  Skipping glow (unsupported arch: $ARCH)"; return 1 ;;
    esac
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/archive.tar.gz" "https://github.com/charmbracelet/glow/releases/download/v${GLOW_VERSION}/glow_${GLOW_VERSION}_Linux_${GLOW_ARCH}.tar.gz"; then
        echo "  Warning: failed to download glow"
        return 1
    fi
    tar xz -C "$TMP" --strip-components=1 -f "$TMP/archive.tar.gz"
    if ! install_to "$TMP/glow" "$BIN_DIR/glow"; then
        echo "  Warning: failed to install glow to $BIN_DIR/glow"
        return 1
    fi
    manifest_add_path "$BIN_DIR/glow"
    echo "  glow $GLOW_VERSION installed to $BIN_DIR/glow"
}

install_gum() {
    if is_macos; then
        brew_install gum gum
        return $?
    fi
    if command -v gum &>/dev/null && ! $FORCE; then
        record_command_if_managed gum || true
        echo "gum already installed: $(gum --version)"
        return 0
    fi
    echo "Installing gum..."
    local GUM_VERSION
    GUM_VERSION="$(gh_latest charmbracelet/gum)" || return 1
    local ARCH GUM_ARCH
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  GUM_ARCH="x86_64" ;;
        aarch64) GUM_ARCH="arm64"  ;;
        *)       echo "  Skipping gum (unsupported arch: $ARCH)"; return 1 ;;
    esac
    # Default BIN_DIR so deploy.sh can source this file and call install_gum
    # without going through setup_main (where BIN_DIR is normally chosen).
    local dest_dir="${BIN_DIR:-$HOME/.local/bin}"
    mkdir -p "$dest_dir" || return 1
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/archive.tar.gz" "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${GUM_ARCH}.tar.gz"; then
        echo "  Warning: failed to download gum"
        return 1
    fi
    tar xz -C "$TMP" --strip-components=1 -f "$TMP/archive.tar.gz"
    if ! install_to "$TMP/gum" "$dest_dir/gum"; then
        echo "  Warning: failed to install gum to $dest_dir/gum"
        return 1
    fi
    manifest_add_path "$dest_dir/gum"
    echo "  gum $GUM_VERSION installed to $dest_dir/gum"
}

install_jq() {
    if is_macos; then
        brew_install jq jq
        return $?
    fi
    if command -v jq &>/dev/null && ! $FORCE; then
        record_command_if_managed jq || true
        echo "jq already installed: $(jq --version 2>&1)"
        return 0
    fi
    echo "Installing jq..."
    local ARCH DEB_ARCH V
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  DEB_ARCH="amd64" ;;
        aarch64) DEB_ARCH="arm64" ;;
        *)       echo "  Skipping jq (unsupported arch: $ARCH)"; return 1 ;;
    esac
    if ! V="$(gh_latest jqlang/jq)"; then
        return 1
    fi
    install_gh_bare_binary jq \
        "https://github.com/jqlang/jq/releases/download/${V}/jq-linux-${DEB_ARCH}"
}

install_node() {
    local MIN_NODE_MAJOR=18
    if is_macos; then
        brew_install node node
        return $?
    fi
    if is_chpc && $CHPC_USE_MODULES; then
        try_chpc_module_load node "Node.js" NODE_MODULE "${NODE_MODULE_CANDIDATES[@]}"
        return
    fi
    if command -v node &>/dev/null && ! $FORCE; then
        local cur_major
        cur_major="$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
        if [ -n "$cur_major" ] && [ "$cur_major" -ge "$MIN_NODE_MAJOR" ] 2>/dev/null; then
            record_node_manifest
            echo "Node.js already installed: $(node --version)"
            return 0
        fi
        echo "Node.js $(node --version) is too old (need >= v${MIN_NODE_MAJOR}). Upgrading..."
    fi
    echo "Installing Node.js..."
    local ARCH NODE_ARCH
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  NODE_ARCH="x64" ;;
        aarch64) NODE_ARCH="arm64" ;;
        *)       echo "  Skipping Node.js (unsupported arch: $ARCH)"; return 1 ;;
    esac
    # Get latest LTS version. Prefer jq, then python3. No grep fallback —
    # the nodejs.org JSON layout is compact but not stable enough for regex,
    # and python3 is effectively always available on our target systems.
    local NODE_VERSION
    if command -v jq &>/dev/null; then
        NODE_VERSION="$(retry curl -sfL https://nodejs.org/dist/index.json \
            | jq -r '[.[] | select(.lts != false)] | .[0].version')"
    elif command -v python3 &>/dev/null; then
        NODE_VERSION="$(retry curl -sfL https://nodejs.org/dist/index.json \
            | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(e['version'] for e in d if e.get('lts')))")"
    else
        echo "  Cannot determine latest Node LTS: neither jq nor python3 is available."
        echo "  Install one of them and re-run, or pass --force after installing Node manually."
        return 1
    fi
    if [ -z "$NODE_VERSION" ]; then
        echo "  Failed to determine latest Node LTS version (empty response)"
        return 1
    fi
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/archive.tar.xz" "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"; then
        echo "  Warning: failed to download Node.js"
        return 1
    fi
    tar xJ -C "$TMP" --strip-components=1 -f "$TMP/archive.tar.xz"
    mkdir -p "$HOME/.local"
    # Remove stale symlinks (e.g. from old nvm-based installs) before copying
    rm -f "$HOME/.local/bin/node" "$HOME/.local/bin/npm" "$HOME/.local/bin/npx" "$HOME/.local/bin/corepack"
    # Install node tree into ~/.local (bin/, lib/, include/, share/)
    if ! cp -rf "$TMP/bin" "$TMP/lib" "$TMP/include" "$TMP/share" "$HOME/.local/"; then
        echo "  Node.js install failed - could not copy files into ~/.local"
        return 1
    fi
    # Clear bash's command hash so it finds the newly installed binaries
    hash -r
    if ! "$HOME/.local/bin/node" --version &>/dev/null; then
        echo "  Node.js install failed — binary not working"
        return 1
    fi
    record_node_manifest
    echo "  Node.js $NODE_VERSION installed to ~/.local"
}

install_uv() {
    if is_macos; then
        brew_install uv uv
        return $?
    fi
    if is_chpc && $CHPC_USE_MODULES; then
        try_chpc_module_load uv "uv" UV_MODULE "${UV_MODULE_CANDIDATES[@]}"
        return
    fi
    if command -v uv &>/dev/null && ! $FORCE; then
        record_command_if_managed uv || true
        record_command_if_managed uvx || true
        echo "uv already installed: $(uv --version)"
        return 0
    fi
    echo "Installing uv..."
    local UV_ARCH TMP
    UV_ARCH="$(machine_arch)"
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/archive.tar.gz" "https://github.com/astral-sh/uv/releases/latest/download/uv-${UV_ARCH}-unknown-linux-musl.tar.gz"; then
        echo "  Warning: failed to download uv"
        return 1
    fi
    tar xz -C "$TMP" -f "$TMP/archive.tar.gz"
    local uv_dir
    uv_dir="$(find "$TMP" -maxdepth 1 -type d -name 'uv-*' | head -1)"
    if [ -z "$uv_dir" ]; then
        echo "  Warning: uv archive had unexpected layout"
        return 1
    fi
    mkdir -p "$HOME/.local/bin"
    if ! mv -f "$uv_dir/uv" "$uv_dir/uvx" "$HOME/.local/bin/"; then
        echo "  Warning: failed to install uv binaries"
        return 1
    fi
    manifest_add_path "$HOME/.local/bin/uv"
    manifest_add_path "$HOME/.local/bin/uvx"
    echo "  uv $(uv --version) installed"
}

nvim_glibc_version() {
    local first_line

    command -v ldd &>/dev/null || return 0
    first_line="$(ldd --version 2>/dev/null | head -1 || true)"
    case "$first_line" in
        *GLIBC*|*GNU\ libc*)
            # Last whitespace-separated token on the line is the version,
            # e.g. "ldd (Ubuntu GLIBC 2.35-0ubuntu3.1) 2.35" -> "2.35".
            printf '%s\n' "$first_line" | awk '{print $NF}'
            ;;
    esac
}

install_nvim_tarball() {
    local label="$1" url="$2" tmp="$3"
    local work_dir extracted_dir install_dir target_bin

    echo "  Trying $label Neovim tarball..."
    rm -rf "$tmp/nvim-tarball" "$tmp/nvim.tar.gz"
    work_dir="$tmp/nvim-tarball"
    mkdir -p "$work_dir" || return 1

    if ! retry curl -sfL -o "$tmp/nvim.tar.gz" "$url"; then
        echo "  Warning: failed to download $label Neovim tarball"
        return 1
    fi
    if ! tar xz -C "$work_dir" -f "$tmp/nvim.tar.gz"; then
        echo "  Warning: failed to extract $label Neovim tarball"
        return 1
    fi

    extracted_dir="$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d | head -1)"
    if [ -z "$extracted_dir" ] || [ ! -x "$extracted_dir/bin/nvim" ]; then
        echo "  Warning: $label Neovim tarball had unexpected layout"
        return 1
    fi
    if ! "$extracted_dir/bin/nvim" --version &>/dev/null; then
        echo "  $label Neovim tarball is not compatible with this system"
        return 1
    fi

    install_dir="$HOME/.local/opt/nvim"
    target_bin="$HOME/.local/bin/nvim"
    if [ -d "$target_bin" ] && [ ! -L "$target_bin" ]; then
        echo "  Warning: cannot replace directory $target_bin"
        return 1
    fi

    mkdir -p "$(dirname "$install_dir")" "$HOME/.local/bin" || return 1
    rm -rf "$install_dir"
    if ! mv "$extracted_dir" "$install_dir"; then
        echo "  Warning: failed to install Neovim to $install_dir"
        return 1
    fi
    rm -f "$target_bin"
    if ! ln -s "$install_dir/bin/nvim" "$target_bin"; then
        echo "  Warning: failed to link Neovim to $target_bin"
        return 1
    fi

    hash -r
    manifest_add_path "$target_bin"
    manifest_add_path "$install_dir"
    echo "  $("$target_bin" --version 2>/dev/null | head -1) installed to $install_dir"
}

install_nvim_appimage() {
    local label="$1" url="$2" tmp="$3"
    local target_bin="$HOME/.local/bin/nvim"

    echo "  Trying $label Neovim AppImage..."
    rm -f "$tmp/nvim.appimage"
    if ! retry curl -sfL -o "$tmp/nvim.appimage" "$url"; then
        echo "  Warning: failed to download $label Neovim AppImage"
        return 1
    fi

    chmod +x "$tmp/nvim.appimage"
    if ! "$tmp/nvim.appimage" --version &>/dev/null; then
        echo "  $label Neovim AppImage is not compatible with this system"
        return 1
    fi
    if [ -d "$target_bin" ] && [ ! -L "$target_bin" ]; then
        echo "  Warning: cannot replace directory $target_bin"
        return 1
    fi

    mkdir -p "$HOME/.local/bin" || return 1
    rm -f "$target_bin"
    if ! mv "$tmp/nvim.appimage" "$target_bin"; then
        echo "  Warning: failed to install Neovim to $target_bin"
        return 1
    fi
    hash -r
    manifest_add_path "$target_bin"
    echo "  $("$target_bin" --version 2>/dev/null | head -1) installed to $target_bin"
}

install_nvim() {
    if is_macos; then
        brew_install neovim nvim
        return $?
    fi
    if is_chpc && $CHPC_USE_MODULES; then
        try_chpc_module_load nvim "Neovim" NVIM_MODULE "${NVIM_MODULE_CANDIDATES[@]}"
        return
    fi
    if command -v nvim &>/dev/null && ! $FORCE; then
        local current_version
        current_version="$(nvim --version 2>/dev/null | head -1 | sed 's/NVIM v//')"
        if version_at_least "${current_version}" "0.9.0"; then
            record_nvim_manifest || true
            echo "nvim already installed: NVIM v${current_version}"
            return 0
        fi
        echo "Upgrading nvim from v${current_version}..."
    fi

    echo "Installing Neovim..."
    local ARCH NVIM_ARCH
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  NVIM_ARCH="x86_64" ;;
        aarch64) NVIM_ARCH="arm64" ;;
        *)  echo "  Skipping nvim (unsupported arch: $ARCH)"; return 1 ;;
    esac

    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN

    local glibc_version official_tarball official_appimage legacy_tarball
    glibc_version="$(nvim_glibc_version)"
    official_tarball="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${NVIM_ARCH}.tar.gz"
    official_appimage="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${NVIM_ARCH}.appimage"
    legacy_tarball="https://github.com/neovim/neovim-releases/releases/latest/download/nvim-linux-x86_64.tar.gz"

    if [ "$ARCH" = "x86_64" ] && [ -n "$glibc_version" ]; then
        if ! version_at_least "$glibc_version" "2.17"; then
            echo "  glibc $glibc_version is too old for Neovim release binaries (need >= 2.17)."
            echo "  Try: ./setup.sh --use-modules   (if on an HPC cluster with an nvim module)"
            return 1
        fi
        if ! version_at_least "$glibc_version" "2.31"; then
            echo "  glibc $glibc_version is old; using Neovim's legacy glibc 2.17 build."
            install_nvim_tarball "legacy" "$legacy_tarball" "$TMP" && return 0
            echo "  Warning: could not install Neovim from the legacy glibc build"
            echo "  Try: ./setup.sh --use-modules   (if on an HPC cluster with an nvim module)"
            return 1
        fi
    fi

    install_nvim_tarball "official" "$official_tarball" "$TMP" && return 0
    install_nvim_appimage "official" "$official_appimage" "$TMP" && return 0

    if [ "$ARCH" = "x86_64" ]; then
        echo "  Falling back to Neovim's legacy glibc 2.17 build..."
        install_nvim_tarball "legacy" "$legacy_tarball" "$TMP" && return 0
    elif [ -n "$glibc_version" ] && ! version_at_least "$glibc_version" "2.31"; then
        echo "  Warning: old-glibc Neovim fallback is only published for x86_64."
    fi

    echo "  Warning: could not install Neovim"
    echo "  Try: ./setup.sh --use-modules   (if on an HPC cluster with an nvim module)"
    return 1
}

install_tree_sitter_cargo() {
    # $1 (optional): version pin, e.g. "0.25.10". When set, cargo installs
    # exactly that version instead of "latest". Pinning matches the prebuilt
    # binary's version when available, so the cargo fallback can't drift
    # away from the version that matches our locked nvim-treesitter.
    local pin="${1:-}"
    if ! command -v cargo &>/dev/null; then
        return 1
    fi
    if [ -n "$pin" ]; then
        echo "  Building tree-sitter $pin from source via cargo (this may take a few minutes)..."
    else
        echo "  Building tree-sitter from source via cargo (this may take a few minutes)..."
    fi
    local TMP cargo_args=(--quiet --locked --root)
    TMP="$(mktemp -d)"
    cargo_args+=("$TMP")
    [ -n "$pin" ] && cargo_args+=(--version "$pin")
    cargo_args+=(tree-sitter-cli)
    if ! cargo install "${cargo_args[@]}" 2>&1 | tail -3; then
        echo "  Warning: cargo install tree-sitter-cli failed"
        rm -rf "$TMP"
        return 1
    fi
    if [ ! -x "$TMP/bin/tree-sitter" ]; then
        echo "  Warning: cargo install did not produce tree-sitter binary"
        rm -rf "$TMP"
        return 1
    fi
    if ! install_to "$TMP/bin/tree-sitter" "$BIN_DIR/tree-sitter"; then
        echo "  Warning: failed to install tree-sitter to $BIN_DIR/tree-sitter"
        rm -rf "$TMP"
        return 1
    fi
    rm -rf "$TMP"
    manifest_add_path "$BIN_DIR/tree-sitter"
    echo "  tree-sitter${pin:+ $pin} (built from source) installed to $BIN_DIR/tree-sitter"
}

install_tree_sitter() {
    if is_macos; then
        brew_install tree-sitter tree-sitter
        return $?
    fi
    # Only short-circuit on successful module load; if no module exists on
    # this CHPC system, fall through to the binary/cargo install path.
    if is_chpc && $CHPC_USE_MODULES && [ "${#TREE_SITTER_MODULE_CANDIDATES[@]}" -gt 0 ]; then
        if try_chpc_module_load tree-sitter "tree-sitter CLI" \
            TREE_SITTER_MODULE "${TREE_SITTER_MODULE_CANDIDATES[@]}"; then
            return 0
        fi
    fi
    if command -v tree-sitter &>/dev/null && ! $FORCE; then
        record_command_if_managed tree-sitter || true
        echo "tree-sitter already installed: $(tree-sitter --version | head -1)"
        return 0
    fi
    echo "Installing tree-sitter CLI..."
    local TS_VERSION
    TS_VERSION="$(gh_latest tree-sitter/tree-sitter)" || return 1
    local ARCH TS_ARCH
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  TS_ARCH="x64"   ;;
        aarch64) TS_ARCH="arm64" ;;
        *)       echo "  Skipping tree-sitter (unsupported arch: $ARCH)"; return 1 ;;
    esac
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/tree-sitter.gz" \
        "https://github.com/tree-sitter/tree-sitter/releases/download/v${TS_VERSION}/tree-sitter-linux-${TS_ARCH}.gz"; then
        echo "  Warning: failed to download tree-sitter"
        install_tree_sitter_cargo "$TS_VERSION"
        return $?
    fi
    if ! gunzip "$TMP/tree-sitter.gz"; then
        echo "  Warning: failed to gunzip tree-sitter"
        install_tree_sitter_cargo "$TS_VERSION"
        return $?
    fi
    chmod +x "$TMP/tree-sitter"
    # The prebuilt binary is dynamically linked against modern glibc; on hosts
    # with older glibc (e.g. CHPC RHEL 8 = glibc 2.28), it fails to run. Probe
    # before installing, and fall back to building from source via cargo at
    # the same version so the binary and cargo paths stay deterministic.
    if ! "$TMP/tree-sitter" --version &>/dev/null; then
        echo "  Prebuilt tree-sitter incompatible with this host's glibc; falling back to cargo build."
        install_tree_sitter_cargo "$TS_VERSION"
        return $?
    fi
    if ! install_to "$TMP/tree-sitter" "$BIN_DIR/tree-sitter"; then
        echo "  Warning: failed to install tree-sitter to $BIN_DIR/tree-sitter"
        return 1
    fi
    manifest_add_path "$BIN_DIR/tree-sitter"
    echo "  tree-sitter $TS_VERSION installed to $BIN_DIR/tree-sitter"
}

install_gh_tools() {
    # jq is installed earlier in setup_main so install_node and friends
    # can use it; it is intentionally absent from this list.
    if [ "${DRY_RUN:-false}" = true ]; then
        for tool in fzf ripgrep fd bat delta zoxide lazygit btop starship atuin; do
            run_step "$tool" true
        done
        return 0
    fi

    if is_macos; then
        run_step "fzf"      brew_install fzf fzf
        run_step "ripgrep"  brew_install ripgrep rg
        run_step "fd"       brew_install fd fd
        run_step "bat"      brew_install bat bat
        run_step "delta"    brew_install git-delta delta
        run_step "zoxide"   brew_install zoxide zoxide
        run_step "lazygit"  brew_install lazygit lazygit
        run_step "btop"     brew_install btop btop
        run_step "starship" brew_install starship starship
        run_step "atuin"    brew_install atuin atuin
        return 0
    fi

    local ARCH DEB_ARCH GH_ARCH
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  DEB_ARCH="amd64"; GH_ARCH="x86_64" ;;
        aarch64) DEB_ARCH="arm64"; GH_ARCH="aarch64" ;;
        *)       echo "Skipping binary installs (unsupported arch: $ARCH)"; return 0 ;;
    esac

    local V

    if V="$(gh_latest junegunn/fzf)"; then
        run_step "fzf" install_gh_binary fzf \
            "https://github.com/junegunn/fzf/releases/download/v${V}/fzf-${V}-linux_${DEB_ARCH}.tar.gz"
    else FAILURES+=("fzf"); fi

    if V="$(gh_latest BurntSushi/ripgrep)"; then
        run_step "ripgrep" install_gh_binary ripgrep \
            "https://github.com/BurntSushi/ripgrep/releases/download/${V}/ripgrep-${V}-${GH_ARCH}-unknown-linux-musl.tar.gz" rg
    else FAILURES+=("ripgrep"); fi

    if V="$(gh_latest sharkdp/fd)"; then
        run_step "fd" install_gh_binary fd \
            "https://github.com/sharkdp/fd/releases/download/v${V}/fd-v${V}-${GH_ARCH}-unknown-linux-musl.tar.gz"
    else FAILURES+=("fd"); fi

    if V="$(gh_latest sharkdp/bat)"; then
        run_step "bat" install_gh_binary bat \
            "https://github.com/sharkdp/bat/releases/download/v${V}/bat-v${V}-${GH_ARCH}-unknown-linux-musl.tar.gz"
    else FAILURES+=("bat"); fi

    if V="$(gh_latest dandavison/delta)"; then
        local DELTA_LIBC="musl"
        [ "$GH_ARCH" = "aarch64" ] && DELTA_LIBC="gnu"
        run_step "delta" install_gh_binary delta \
            "https://github.com/dandavison/delta/releases/download/${V}/delta-${V}-${GH_ARCH}-unknown-linux-${DELTA_LIBC}.tar.gz"
    else FAILURES+=("delta"); fi

    if V="$(gh_latest ajeetdsouza/zoxide)"; then
        run_step "zoxide" install_gh_binary zoxide \
            "https://github.com/ajeetdsouza/zoxide/releases/download/v${V}/zoxide-${V}-${GH_ARCH}-unknown-linux-musl.tar.gz"
    else FAILURES+=("zoxide"); fi

    local LAZYGIT_ARCH="$GH_ARCH"
    [ "$LAZYGIT_ARCH" = "aarch64" ] && LAZYGIT_ARCH="arm64"
    if V="$(gh_latest jesseduffield/lazygit)"; then
        run_step "lazygit" install_gh_binary lazygit \
            "https://github.com/jesseduffield/lazygit/releases/download/v${V}/lazygit_${V}_Linux_${LAZYGIT_ARCH}.tar.gz"
    else FAILURES+=("lazygit"); fi

    if is_chpc && $CHPC_USE_MODULES; then
        run_step "btop" try_chpc_module_load btop "btop" BTOP_MODULE "${BTOP_MODULE_CANDIDATES[@]}"
    elif V="$(gh_latest aristocratos/btop)"; then
        run_step "btop" install_gh_binary btop \
            "https://github.com/aristocratos/btop/releases/download/v${V}/btop-${GH_ARCH}-unknown-linux-musl.tar.gz" btop
    else FAILURES+=("btop"); fi

    if V="$(gh_latest starship/starship)"; then
        run_step "starship" install_gh_binary starship \
            "https://github.com/starship/starship/releases/download/v${V}/starship-${GH_ARCH}-unknown-linux-musl.tar.gz"
    else FAILURES+=("starship"); fi

    if V="$(gh_latest atuinsh/atuin)"; then
        run_step "atuin" install_gh_binary atuin \
            "https://github.com/atuinsh/atuin/releases/download/v${V}/atuin-${GH_ARCH}-unknown-linux-musl.tar.gz"
    else FAILURES+=("atuin"); fi
}

install_claude() {
    if is_chpc && $CHPC_USE_MODULES; then
        try_chpc_module_load claude "Claude Code" CLAUDE_MODULE "${CLAUDE_MODULE_CANDIDATES[@]}"
        return
    fi

    if command -v claude &>/dev/null && ! $FORCE; then
        record_command_if_managed claude || true
        echo "Claude Code already installed: $(claude --version 2>&1 | head -1)"
        return 0
    fi
    echo "Installing Claude Code..."
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -fsSL -o "$TMP/install.sh" https://claude.ai/install.sh; then
        echo "  Warning: failed to download Claude Code installer"
        return 1
    fi
    if ! bash "$TMP/install.sh"; then
        echo "  Warning: Claude Code installer exited with an error"
        return 1
    fi
    hash -r
    if ! command -v claude &>/dev/null; then
        echo "  Claude Code install failed - 'claude' not found after installer ran"
        return 1
    fi
    record_command_if_managed claude || true
    echo "  Run 'claude' to authenticate and get started."
}

install_codex() {
    if is_chpc && $CHPC_USE_MODULES; then
        try_chpc_module_load codex "Codex" CODEX_MODULE "${CODEX_MODULE_CANDIDATES[@]}"
        return
    fi

    if command -v codex &>/dev/null && ! $FORCE; then
        record_command_if_managed codex || true
        echo "Codex CLI already installed: $(codex --version 2>&1 | head -1)"
        return 0
    fi
    echo "Installing Codex CLI..."
    # gh_latest returns the full tag (e.g. "rust-v0.120.0") since the tag isn't a plain "v*"
    local CODEX_TAG
    CODEX_TAG="$(gh_latest openai/codex)" || return 1
    local ARCH TARGET
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64|aarch64) ;;
        *) echo "  Skipping Codex CLI (unsupported arch: $ARCH)"; return 1 ;;
    esac
    if is_macos; then
        TARGET="apple-darwin"
    else
        TARGET="unknown-linux-musl"
    fi
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN

    # Resolve the asset URL from the release JSON when possible, so
    # OpenAI changing the asset filename pattern doesn't silently break
    # installs. Fall back to the historical pattern if jq is missing or
    # the API lookup fails.
    local CODEX_ASSET_URL=""
    if command -v jq &>/dev/null; then
        CODEX_ASSET_URL="$(retry curl -sfL "https://api.github.com/repos/openai/codex/releases/tags/${CODEX_TAG}" 2>/dev/null \
            | jq -r --arg arch "$ARCH" --arg target "$TARGET" '
                .assets[]
                | select(.name | test("codex-" + $arch + "-" + $target + "\\.tar\\.gz$"))
                | .browser_download_url' 2>/dev/null \
            | head -1)"
    fi
    if [ -z "$CODEX_ASSET_URL" ]; then
        CODEX_ASSET_URL="https://github.com/openai/codex/releases/download/${CODEX_TAG}/codex-${ARCH}-${TARGET}.tar.gz"
    fi

    if ! retry curl -sfL -o "$TMP/archive.tar.gz" "$CODEX_ASSET_URL"; then
        echo "  Warning: failed to download Codex CLI from $CODEX_ASSET_URL"
        return 1
    fi
    if ! tar xz -C "$TMP" -f "$TMP/archive.tar.gz"; then
        echo "  Warning: failed to extract Codex archive"
        return 1
    fi
    # Locate the codex binary in the extracted tree by name pattern, so
    # we don't depend on the exact filename layout inside the tarball.
    local codex_bin
    codex_bin="$(find "$TMP" -maxdepth 2 -type f -name 'codex*' ! -name '*.tar.gz' | head -1)"
    if [ -z "$codex_bin" ]; then
        echo "  Warning: Codex archive did not contain a codex binary"
        return 1
    fi
    chmod +x "$codex_bin"
    if ! install_to "$codex_bin" "$BIN_DIR/codex"; then
        echo "  Warning: failed to install Codex CLI to $BIN_DIR/codex"
        return 1
    fi
    if ! codex --version &>/dev/null; then
        echo "  Codex CLI install failed — binary not working"
        return 1
    fi
    manifest_add_path "$BIN_DIR/codex"
    echo "  Codex CLI $(codex --version 2>&1 | head -1) installed to $BIN_DIR"
}

install_tpm() {
    local tpm_dir="$HOME/.tmux/plugins/tpm"
    if [ -d "$tpm_dir" ]; then
        echo "TPM already installed"
        return 0
    fi
    echo "Installing TPM (Tmux Plugin Manager)..."
    if ! git clone --depth 1 https://github.com/tmux-plugins/tpm "$tpm_dir" 2>/dev/null; then
        echo "  Warning: failed to clone TPM"
        return 1
    fi
    echo "  TPM installed. Press prefix + I inside tmux to install plugins."
}

install_plugins() {
    "$DIR/install_claude_plugins.sh"
}

install_chpc_allocs() {
    if ! is_chpc; then
        echo "  Skipping chpc-allocs (not on CHPC)"
        return 0
    fi
    if [ ! -f "$DIR/chpc-allocs.py" ]; then
        echo "  Skipping chpc-allocs (source missing)"
        return 1
    fi
    chmod +x "$DIR/chpc-allocs.py" 2>/dev/null || true
    backup_and_link "$DIR/chpc-allocs.py" "$BIN_DIR/chpc-allocs" || return 1
    manifest_add_path "$BIN_DIR/chpc-allocs"
}

link_core_configs() {
    mkdir -p "$HOME/.config" "$HOME/.ssh/sockets" "$HOME/.vim/undodir" || return 1
    backup_and_link "$DIR/vimrc" "$HOME/.vimrc" || return 1
    backup_and_link "$DIR/tmux.conf" "$HOME/.tmux.conf" || return 1
    backup_and_link "$DIR/nvim" "$HOME/.config/nvim" || return 1
    backup_and_link "$DIR/gitconfig" "$HOME/.gitconfig" || return 1
    backup_and_link "$DIR/inputrc" "$HOME/.inputrc" || return 1
    backup_and_link "$DIR/dircolors" "$HOME/.dircolors" || return 1
    backup_and_link "$DIR/dircolors.light" "$HOME/.dircolors.light" || return 1
    backup_and_link "$DIR/sshconfig" "$HOME/.ssh/config" || return 1
    backup_and_link "$DIR/starship.toml" "$HOME/.config/starship.toml" || return 1
    backup_and_link "$DIR/starship-light.toml" "$HOME/.config/starship-light.toml" || return 1
    # XDG-compliant tmux path (tmux 3.2+ reads this natively)
    mkdir -p "$HOME/.config/tmux" 2>/dev/null || true
    backup_and_link "$DIR/tmux.conf" "$HOME/.config/tmux/tmux.conf" || return 1
}

link_generated_configs() {
    backup_and_link "$DIR/bashrc_exports" "$HOME/.bashrc_exports" || return 1
    backup_and_link "$DIR/bashrc_aliases" "$HOME/.bashrc_aliases" || return 1
    backup_and_copy "$CLAUDE_SETTINGS_SRC" "$HOME/.claude/settings.json" || return 1
    manifest_add_path "$HOME/.claude/settings.json" || return 1
    backup_and_copy "$CODEX_CONFIG_SRC" "$HOME/.codex/config.toml" || return 1
    manifest_add_path "$HOME/.codex/config.toml" || return 1
    append_line_if_missing 'source ~/.bashrc_exports' "$HOME/.bashrc" || return 1
    append_line_if_missing 'source ~/.bashrc_aliases' "$HOME/.bashrc" || return 1
}

setup_main() {
    FORCE=false
    DRY_RUN=false
    FAILURES=()
    reset_module_vars

    for arg in "$@"; do
        case "$arg" in
            --force|-f) FORCE=true ;;
            --dry-run|-n) DRY_RUN=true ;;
            --use-modules|-m) CHPC_USE_MODULES=true ;;
            --probe-modules)
                probe_chpc_modules
                return $?
                ;;
            -h|--help)
                echo "Usage: setup.sh [--force|-f] [--dry-run|-n] [--use-modules|-m] [--probe-modules] [--help|-h]"
                echo "  -f, --force        Reinstall CLI tools even if already present"
                echo "  -n, --dry-run      Show setup steps without changing files"
                echo "  -m, --use-modules  On CHPC, prefer module load over binary install"
                echo "      --probe-modules  Report which CHPC module candidates resolve, then exit"
                echo "  -h, --help         Show this help"
                return 0
                ;;
            *)
                echo "Unknown option: $arg"
                echo "Run './setup.sh --help' for usage."
                return 1
                ;;
        esac
    done

    export PATH="$HOME/.local/bin:$PATH"
    trap _setup_cleanup EXIT

    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$GENERATED_DIR" || return 1
        chmod 700 "$GENERATED_DIR" 2>/dev/null || true
        # Manifest contract: truncate-and-rebuild on every run. Each
        # idempotent install function calls manifest_add_path /
        # record_command_if_managed even on its early-return path, so a
        # successful re-run (no install steps invoked) still produces a
        # complete manifest. If a run dies mid-way, the next run rebuilds
        # cleanly. Do NOT call uninstall.sh between a killed run and a
        # subsequent re-run — the partial manifest will leak un-tracked
        # files. Tested by test_manifest_controls_uninstall.
        : > "$INSTALL_MANIFEST"

        # Point this clone at the repo-local git hooks (idempotent; only when
        # run from inside the repo itself).
        if [ -d "$DIR/.git" ] && command -v git &>/dev/null; then
            git -C "$DIR" config core.hooksPath .githooks 2>/dev/null || true
        fi

        # Drop the shell-init cache so the next interactive bash regenerates
        # `atuin init`, `zoxide init`, `fzf --bash` against any newly
        # installed/upgraded binaries (matches I14 in the robustness plan).
        rm -rf "$HOME/.cache/server-configs" 2>/dev/null || true
    fi

    echo "Linking config files..."
    run_step "core config links" link_core_configs

    # Determine install directories based on write access
    NEED_SUDO=""
    if [ "$DRY_RUN" = true ]; then
        BIN_DIR="$HOME/.local/bin"
    elif is_macos; then
        BIN_DIR="$HOME/.local/bin"
        mkdir -p "$BIN_DIR"
    elif [ -w /usr/local/bin ]; then
        BIN_DIR="/usr/local/bin"
    elif command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
        BIN_DIR="/usr/local/bin"
        NEED_SUDO=1
    else
        BIN_DIR="$HOME/.local/bin"
        mkdir -p "$BIN_DIR"
    fi

    # Install tools (each step continues on failure).
    # jq goes first so install_node (which parses the nodejs.org JSON index)
    # can use it instead of falling back to python3 — and so any future
    # caller can rely on jq being present.
    run_step "gh"           install_gh_cli
    run_step "jq"           install_jq
    run_step "glow"         install_glow
    run_step "gum"          install_gum
    run_step "node"         install_node
    run_step "uv"           install_uv
    install_gh_tools
    run_step "tree-sitter"  install_tree_sitter
    run_step "nvim"         install_nvim
    run_step "tpm"          install_tpm
    run_step "claude"       install_claude
    run_step "codex"        install_codex
    run_step "chpc-allocs"  install_chpc_allocs

    run_step "compat configs" render_compat_configs

    # Link remaining configs
    run_step "shell config links" link_generated_configs
    # Source bashrc only in interactive shells; non-interactive may lack shopt etc.
    if [[ $- == *i* ]] && [ "$DRY_RUN" = false ]; then
        # shellcheck source=/dev/null
        source "$HOME/.bashrc"
    fi

    run_step "mcp plugins" install_plugins

    # --- Summary ---
    echo ""
    if [ ${#FAILURES[@]} -gt 0 ]; then
        echo "Setup complete with ${#FAILURES[@]} warning(s):"
        for f in "${FAILURES[@]}"; do
            echo "  - $f (optional)"
        done
        echo ""
        echo "Compatibility report: $GENERATED_DIR/compat-report.txt"
        echo "Start a new tmux session or run: tmux source ~/.tmux.conf"
    else
        echo "Compatibility report: $GENERATED_DIR/compat-report.txt"
        echo "Setup complete! Start a new tmux session or run: tmux source ~/.tmux.conf"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    setup_main "$@"
fi
