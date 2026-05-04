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
NVIM_MODULE=""
CLAUDE_MODULE=""
CODEX_MODULE=""
CLAUDE_MODULE_CANDIDATES=("claude-code" "claude")
CODEX_MODULE_CANDIDATES=("codex" "openai-codex")
FORCE="${FORCE:-false}"
DRY_RUN="${DRY_RUN:-false}"
FAILURES=()

_setup_cleanup() {
    :
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

claude_supports_skip_permissions() {
    command -v claude &>/dev/null || return 1
    command_output_contains '--dangerously-skip-permissions' claude --help
}

claude_supports_remote_control() {
    command -v claude &>/dev/null || return 1
    claude --remote-control --version >/dev/null 2>&1
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

codex_supports_bypass() {
    command -v codex &>/dev/null || return 1
    command_output_contains '--dangerously-bypass-approvals-and-sandbox' codex --help
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
    echo "  Check available modules with: module spider $cmd"
    return 1
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
    local claude_alias="claude"
    local codex_alias="codex"

    if ! is_chpc && command -v claude &>/dev/null; then
        if claude_supports_skip_permissions; then
            claude_alias+=" --dangerously-skip-permissions"
        fi
        if claude_supports_remote_control; then
            claude_alias+=" --remote-control"
        fi
    fi

    if ! is_chpc && command -v codex &>/dev/null && codex_supports_bypass; then
        codex_alias+=" --dangerously-bypass-approvals-and-sandbox"
    fi

    cat > "$GENERATED_DIR/bashrc_compat" <<EOF
# Generated by setup.sh. Re-run setup.sh after upgrading Claude Code or Codex CLI.
if [ -n "\${SERVER_CONFIGS_BASH_COMPAT_LOADED:-}" ]; then
    return 0
fi
SERVER_CONFIGS_BASH_COMPAT_LOADED=1

alias claude='${claude_alias}'
alias codex='${codex_alias}'
EOF

    # If any tool was installed via module, persist module initialization once.
    if [ -n "${NVIM_MODULE:-}" ] || [ -n "${CLAUDE_MODULE:-}" ] || [ -n "${CODEX_MODULE:-}" ]; then
        cat >> "$GENERATED_DIR/bashrc_compat" <<EOF

# Environment modules
if ! command -v module &>/dev/null; then
    for init in /etc/profile.d/modules.sh /etc/profile.d/lmod.sh /usr/share/Modules/init/bash; do
        if [ -r "\$init" ]; then
            . "\$init" >/dev/null 2>&1 && break
        fi
    done
fi
EOF
    fi

    local mod_load mod_val
    for mod_load in NVIM_MODULE CLAUDE_MODULE CODEX_MODULE; do
        mod_val="${!mod_load:-}"
        if [ -n "$mod_val" ]; then
            cat >> "$GENERATED_DIR/bashrc_compat" <<EOF
command -v module &>/dev/null && module load ${mod_val} 2>/dev/null
EOF
        fi
    done
}

render_claude_settings_target() {
    CLAUDE_SETTINGS_SRC="$DIR/claude_settings.json"
    CLAUDE_SETTINGS_MODE="repo"

    if is_chpc; then
        cat > "$GENERATED_DIR/claude_settings.json" <<'EOF'
{
  "defaultMode": "default",
  "skipDangerousModePermissionPrompt": false,
  "sandbox": { "enabled": true, "failIfUnavailable": false, "autoAllowBashIfSandboxed": true },
  "enableAllProjectMcpServers": false,
  "model": "opus",
  "autoUpdatesChannel": "stable",
  "editorMode": "vim",
  "showTurnDuration": true,
  "spinnerTipsEnabled": true,
  "alwaysThinkingEnabled": true,
  "effortLevel": "high",
  "hooks": {
    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "printf '\\a' > /dev/tty"}]}],
    "Notification": [{"matcher": "", "hooks": [{"type": "command", "command": "printf '\\a' > /dev/tty"}]}]
  }
}
EOF
        CLAUDE_SETTINGS_SRC="$GENERATED_DIR/claude_settings.json"
        CLAUDE_SETTINGS_MODE="chpc"
        return 0
    fi

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

    if is_chpc; then
        cat > "$GENERATED_DIR/codex_config.toml" <<'EOF'
# Generated by setup.sh for CHPC — approval required per CHPC AI policy.
model_reasoning_effort = "high"
plan_mode_reasoning_effort = "xhigh"
commit_attribution = ""
approval_policy = "untrusted"
sandbox_mode = "workspace-write"

[shell_environment_policy]
inherit = "all"

[history]
persistence = "save-all"
max_bytes = 52428800

[tui]
notifications = true
animations = true
EOF
        CODEX_CONFIG_SRC="$GENERATED_DIR/codex_config.toml"
        CODEX_CONFIG_MODE="chpc"
        return 0
    fi

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

# Get latest release version from GitHub (strips leading 'v')
gh_latest() {
    local version
    version="$(retry curl -sfI "https://github.com/$1/releases/latest" \
        | grep -i '^location:' | sed 's|.*/v\?\([^/[:space:]]*\).*|\1|')"
    if [ -z "$version" ]; then
        echo "  Warning: could not determine latest version for $1" >&2
        return 1
    fi
    echo "$version"
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

install_node() {
    local MIN_NODE_MAJOR=18
    if is_macos; then
        brew_install node node
        return $?
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

install_nvim() {
    if is_macos; then
        brew_install neovim nvim
        return $?
    fi
    if command -v nvim &>/dev/null && ! $FORCE; then
        local current_version
        current_version="$(nvim --version 2>/dev/null | head -1 | sed 's/NVIM v//')"
        if version_at_least "${current_version}" "0.9.0"; then
            record_command_if_managed nvim || true
            echo "nvim already installed: NVIM v${current_version}"
            return 0
        fi
        echo "Upgrading nvim from v${current_version}..."
    fi

    # Strategy 1: Try loading an environment module (common on HPC clusters)
    if ensure_module_command; then
        local mod
        for mod in nvim/0.11.2 nvim; do
            if module load "$mod" 2>/dev/null && command -v nvim &>/dev/null; then
                local mod_version
                mod_version="$(nvim --version 2>/dev/null | head -1 | sed 's/NVIM v//')"
                if version_at_least "${mod_version}" "0.9.0"; then
                    echo "  nvim available via module: NVIM v${mod_version}"
                    NVIM_MODULE="$mod"
                    hash -r
                    return 0
                fi
            fi
        done
    fi

    # Strategy 2: Download AppImage from GitHub releases
    echo "Installing Neovim..."
    local ARCH
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64|aarch64) ;;
        *)  echo "  Skipping nvim (unsupported arch: $ARCH)"; return 1 ;;
    esac

    # Pre-check glibc. Latest nvim AppImage needs ~2.31; 0.9.5 needs ~2.28.
    # If we're below 2.28, skip the AppImage path entirely — it will just fail.
    local glibc_version=""
    if command -v ldd &>/dev/null; then
        glibc_version="$(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')"
    fi
    if [ -n "$glibc_version" ] && ! version_at_least "$glibc_version" "2.28"; then
        echo "  glibc $glibc_version is too old for any nvim AppImage (need >= 2.28)."
        echo "  Try: module load nvim   (if on an HPC cluster), or install from tarball manually."
        return 1
    fi

    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN

    # Build the candidate list based on glibc. Latest needs >= 2.31; otherwise
    # only v0.9.5 is worth trying.
    local candidates=()
    if [ -z "$glibc_version" ] || version_at_least "$glibc_version" "2.31"; then
        candidates+=("latest/download")
    fi
    candidates+=("v0.9.5")

    local url version_tag
    for version_tag in "${candidates[@]}"; do
        local file_name="nvim-linux-${ARCH}.appimage"
        # v0.9.5 used a different asset name
        [ "$version_tag" = "v0.9.5" ] && file_name="nvim.appimage"

        url="https://github.com/neovim/neovim/releases/${version_tag}/${file_name}"
        if retry curl -sfL -o "$TMP/nvim.appimage" "$url"; then
            chmod +x "$TMP/nvim.appimage"
            if "$TMP/nvim.appimage" --version &>/dev/null; then
                if ! install_to "$TMP/nvim.appimage" "$BIN_DIR/nvim"; then
                    echo "  Warning: failed to install Neovim to $BIN_DIR/nvim"
                    return 1
                fi
                hash -r
                manifest_add_path "$BIN_DIR/nvim"
                echo "  $(nvim --version 2>/dev/null | head -1) installed to $BIN_DIR/nvim"
                return 0
            fi
            echo "  AppImage from $version_tag not compatible with this system, trying next..."
            rm -f "$TMP/nvim.appimage"
        fi
    done

    echo "  Warning: could not install Neovim (glibc too old for AppImage)"
    echo "  Try: module load nvim   (if on an HPC cluster)"
    return 1
}

install_gh_tools() {
    if [ "${DRY_RUN:-false}" = true ]; then
        for tool in fzf ripgrep fd bat delta zoxide lazygit btop jq starship atuin; do
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
        run_step "jq"       brew_install jq jq
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

    if V="$(gh_latest aristocratos/btop)"; then
        run_step "btop" install_gh_binary btop \
            "https://github.com/aristocratos/btop/releases/download/v${V}/btop-${GH_ARCH}-unknown-linux-musl.tbz" btop
    else FAILURES+=("btop"); fi

    if V="$(gh_latest jqlang/jq)"; then
        run_step "jq" install_gh_bare_binary jq \
            "https://github.com/jqlang/jq/releases/download/${V}/jq-linux-${DEB_ARCH}"
    else FAILURES+=("jq"); fi

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
    if is_chpc; then
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
    if is_chpc; then
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
    if ! retry curl -sfL -o "$TMP/archive.tar.gz" \
        "https://github.com/openai/codex/releases/download/${CODEX_TAG}/codex-${ARCH}-${TARGET}.tar.gz"; then
        echo "  Warning: failed to download Codex CLI"
        return 1
    fi
    tar xz -C "$TMP" -f "$TMP/archive.tar.gz"
    chmod +x "$TMP/codex-${ARCH}-${TARGET}"
    if ! install_to "$TMP/codex-${ARCH}-${TARGET}" "$BIN_DIR/codex"; then
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

link_core_configs() {
    mkdir -p "$HOME/.config" "$HOME/.ssh/sockets" "$HOME/.vim/undodir" || return 1
    backup_and_link "$DIR/vimrc" "$HOME/.vimrc" || return 1
    backup_and_link "$DIR/tmux.conf" "$HOME/.tmux.conf" || return 1
    backup_and_link "$DIR/nvim" "$HOME/.config/nvim" || return 1
    backup_and_link "$DIR/gitconfig" "$HOME/.gitconfig" || return 1
    backup_and_link "$DIR/inputrc" "$HOME/.inputrc" || return 1
    backup_and_link "$DIR/dircolors" "$HOME/.dircolors" || return 1
    backup_and_link "$DIR/sshconfig" "$HOME/.ssh/config" || return 1
    backup_and_link "$DIR/starship.toml" "$HOME/.config/starship.toml" || return 1
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
    NVIM_MODULE=""
    CLAUDE_MODULE=""
    CODEX_MODULE=""

    for arg in "$@"; do
        case "$arg" in
            --force|-f) FORCE=true ;;
            --dry-run|-n) DRY_RUN=true ;;
            -h|--help)
                echo "Usage: setup.sh [--force|-f] [--dry-run|-n] [--help|-h]"
                echo "  -f, --force    Reinstall CLI tools even if already present"
                echo "  -n, --dry-run  Show setup steps without changing files"
                echo "  -h, --help     Show this help"
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
        : > "$INSTALL_MANIFEST"

        # Point this clone at the repo-local git hooks (idempotent; only when
        # run from inside the repo itself).
        if [ -d "$DIR/.git" ] && command -v git &>/dev/null; then
            git -C "$DIR" config core.hooksPath .githooks 2>/dev/null || true
        fi
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

    # Install tools (each step continues on failure)
    run_step "gh"           install_gh_cli
    run_step "glow"         install_glow
    run_step "node"         install_node
    run_step "uv"           install_uv
    install_gh_tools
    run_step "nvim"         install_nvim
    run_step "tpm"          install_tpm
    run_step "claude"       install_claude
    run_step "codex"        install_codex

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
