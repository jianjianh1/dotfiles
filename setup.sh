#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# Ensure ~/.local/bin is in PATH (node symlinks, uv, etc. live here)
export PATH="$HOME/.local/bin:$PATH"

# --- Flags ---
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=true ;;
    esac
done

# --- Error tracking ---
FAILURES=()

run_step() {
    local name="$1"; shift
    if ! "$@"; then
        FAILURES+=("$name")
    fi
}

# --- Helpers ---

# Symlink configs (back up existing real files/dirs; overwrite existing symlinks)
backup_and_link() {
    local src="$1" dst="$2"
    if [ -L "$dst" ]; then
        rm -f "$dst"
    elif [ -e "$dst" ]; then
        rm -rf "${dst}.bak" 2>/dev/null || true
        echo "  Backing up $dst -> ${dst}.bak"
        mv -f "$dst" "${dst}.bak"
    fi
    ln -sf "$src" "$dst"
    echo "  $src -> $dst"
}

# Wrapper: move/copy files respecting sudo needs
install_to() {
    local src="$1" dst="$2"
    if [ -n "$NEED_SUDO" ]; then
        sudo mv -f "$src" "$dst"
    else
        mv -f "$src" "$dst"
    fi
}

# Retry a command up to 3 times with a 2-second delay
retry() {
    local attempts=3 delay=2 n=0
    while ! "$@"; do
        n=$((n + 1))
        if [ "$n" -ge "$attempts" ]; then return 1; fi
        echo "  Retrying ($n/$attempts)..."
        sleep "$delay"
    done
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
    install_to "$bin" "$BIN_DIR/$bin_name"
    echo "  $name installed to $BIN_DIR/$bin_name"
}

# Install a .deb from a GitHub release (extracts binary if no dpkg/sudo)
install_gh_deb() {
    local name="$1" url="$2"
    if command -v "$name" &>/dev/null && ! $FORCE; then
        echo "$name already installed"
        return 0
    fi
    echo "Installing $name..."
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/$name.deb" "$url"; then
        echo "  Warning: failed to download $name"
        return 1
    fi
    if [ -w /usr/bin ] || [ -n "$NEED_SUDO" ]; then
        if [ -n "$NEED_SUDO" ]; then
            sudo dpkg -i "$TMP/$name.deb"
        else
            dpkg -i "$TMP/$name.deb"
        fi
    else
        # No sudo — extract binary from .deb manually
        (
            cd "$TMP"
            if command -v dpkg-deb &>/dev/null; then
                dpkg-deb -x "$name.deb" .
            else
                ar x "$name.deb"
                # Handle gz/xz/zst compression (tar may not support zst)
                tar xf data.tar.* 2>/dev/null || true
            fi
        )
        local bin
        bin="$(find "$TMP" -type f -name "$name" -path '*/bin/*' | head -1)"
        if [ -n "$bin" ]; then
            chmod +x "$bin"
            mv "$bin" "$BIN_DIR/$name"
        else
            echo "  Warning: $name binary not found in .deb"
            return 1
        fi
    fi
    echo "  $name installed"
}

# --- Install functions ---

install_glow() {
    if command -v glow &>/dev/null && ! $FORCE; then
        echo "glow already installed: $(glow --version)"
        return 0
    fi
    echo "Installing glow..."
    local GLOW_VERSION
    GLOW_VERSION="$(gh_latest charmbracelet/glow)" || return 1
    local ARCH GLOW_ARCH
    ARCH="$(uname -m)"
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
    install_to "$TMP/glow" "$BIN_DIR/glow"
    echo "  glow $GLOW_VERSION installed to $BIN_DIR/glow"
}

install_node() {
    if command -v node &>/dev/null && ! $FORCE; then
        echo "Node.js already installed: $(node --version)"
        return 0
    fi
    echo "Installing Node.js..."
    local ARCH NODE_ARCH
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  NODE_ARCH="x64" ;;
        aarch64) NODE_ARCH="arm64" ;;
        *)       echo "  Skipping Node.js (unsupported arch: $ARCH)"; return 1 ;;
    esac
    # Get latest LTS version (prefer jq, fall back to regex)
    local NODE_VERSION
    NODE_VERSION="$(retry curl -sfL https://nodejs.org/dist/index.json \
        | if command -v jq &>/dev/null; then
            jq -r '[.[] | select(.lts != false)] | .[0].version'
        elif command -v python3 &>/dev/null; then
            python3 -c "import json,sys; d=json.load(sys.stdin); print(next(e['version'] for e in d if e.get('lts')))"
        else
            # Compact JSON: each entry on one line (fragile if format changes)
            grep -o '"version":"v[0-9.]*".*"lts":"[^f][^"]*"' | head -1 \
            | grep -o '"version":"v[^"]*"' | cut -d'"' -f4
        fi)"
    if [ -z "$NODE_VERSION" ]; then
        echo "  Failed to determine latest LTS version"
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
    cp -rf "$TMP/bin" "$TMP/lib" "$TMP/include" "$TMP/share" "$HOME/.local/"
    # Clear bash's command hash so it finds the newly installed binaries
    hash -r
    if ! "$HOME/.local/bin/node" --version &>/dev/null; then
        echo "  Node.js install failed — binary not working"
        return 1
    fi
    echo "  Node.js $NODE_VERSION installed to ~/.local"
}

install_uv() {
    if command -v uv &>/dev/null && ! $FORCE; then
        echo "uv already installed: $(uv --version)"
        return 0
    fi
    echo "Installing uv..."
    local UV_ARCH TMP
    UV_ARCH="$(uname -m)"
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
    mv -f "$uv_dir/uv" "$uv_dir/uvx" "$HOME/.local/bin/"
    echo "  uv $(uv --version) installed"
}

install_apt_packages() {
    if ! command -v apt-get &>/dev/null || { ! [ -w /usr/bin ] && [ -z "$NEED_SUDO" ]; }; then
        command -v jq   &>/dev/null || echo "Skipping jq (no apt/sudo — install manually)"
        command -v htop &>/dev/null || echo "Skipping htop (no apt/sudo — install manually)"
        return 0
    fi
    PKGS=()
    command -v jq    &>/dev/null || PKGS+=(jq)
    command -v htop  &>/dev/null || PKGS+=(htop)
    if [ ${#PKGS[@]} -gt 0 ]; then
        echo "Installing apt packages: ${PKGS[*]}..."
        if [ -n "$NEED_SUDO" ]; then
            sudo apt-get update -qq && sudo apt-get install -y -qq "${PKGS[@]}"
        else
            apt-get update -qq && apt-get install -y -qq "${PKGS[@]}"
        fi
    fi
}

install_gh_tools() {
    local ARCH DEB_ARCH GH_ARCH
    ARCH="$(uname -m)"
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
        run_step "bat" install_gh_deb bat \
            "https://github.com/sharkdp/bat/releases/download/v${V}/bat_${V}_${DEB_ARCH}.deb"
    else FAILURES+=("bat"); fi

    if V="$(gh_latest dandavison/delta)"; then
        run_step "delta" install_gh_deb delta \
            "https://github.com/dandavison/delta/releases/download/${V}/git-delta_${V}_${DEB_ARCH}.deb"
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
}

install_claude() {
    if command -v claude &>/dev/null && ! $FORCE; then
        echo "Claude Code already installed: $(claude --version 2>&1 | head -1)"
        return 0
    fi
    echo "Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
    echo "  Run 'claude' to authenticate and get started."
}

install_codex() {
    if command -v codex &>/dev/null && ! $FORCE; then
        echo "Codex CLI already installed: $(codex --version 2>&1 | head -1)"
        return 0
    fi
    # Run node + npm-cli.js directly to bypass #!/usr/bin/env node shebang issues
    local node_bin="$HOME/.local/bin/node"
    local npm_cli="$HOME/.local/lib/node_modules/npm/bin/npm-cli.js"
    if [ ! -x "$node_bin" ] || [ ! -f "$npm_cli" ]; then
        echo "Skipping Codex CLI (Node.js not found — install Node.js first)"
        return 1
    fi
    echo "Installing Codex CLI..."
    "$node_bin" "$npm_cli" install -g @openai/codex
    hash -r
    if ! command -v codex &>/dev/null; then
        echo "  Codex CLI install failed"
        return 1
    fi
    echo "  Codex CLI installed"
}

install_plugins() {
    "$DIR/install_claude_plugins.sh"
}

# ============================================================
# Main
# ============================================================

echo "Linking config files..."
backup_and_link "$DIR/vimrc"     "$HOME/.vimrc"
backup_and_link "$DIR/tmux.conf" "$HOME/.tmux.conf"
backup_and_link "$DIR/gitconfig" "$HOME/.gitconfig"
backup_and_link "$DIR/inputrc"   "$HOME/.inputrc"
backup_and_link "$DIR/dircolors" "$HOME/.dircolors"
mkdir -p "$HOME/.ssh/sockets"
backup_and_link "$DIR/sshconfig" "$HOME/.ssh/config"

# Create vim undo directory
mkdir -p "$HOME/.vim/undodir"

# Determine install directories based on write access
NEED_SUDO=""
if [ -w /usr/local/bin ]; then
    BIN_DIR="/usr/local/bin"
elif command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
    BIN_DIR="/usr/local/bin"
    NEED_SUDO=1
else
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
fi

# Install tools (each step continues on failure)
run_step "glow"         install_glow
run_step "node"         install_node
run_step "uv"           install_uv
run_step "apt packages" install_apt_packages
install_gh_tools
run_step "claude"       install_claude
run_step "codex"        install_codex

# Link remaining configs
backup_and_link "$DIR/bashrc_exports" "$HOME/.bashrc_exports"
backup_and_link "$DIR/bashrc_aliases" "$HOME/.bashrc_aliases"
mkdir -p "$HOME/.claude"
backup_and_link "$DIR/claude_settings.json" "$HOME/.claude/settings.json"
mkdir -p "$HOME/.codex"
backup_and_link "$DIR/codex_config.toml" "$HOME/.codex/config.toml"
if ! grep -qF 'source ~/.bashrc_exports' ~/.bashrc 2>/dev/null; then
    echo 'source ~/.bashrc_exports' >> ~/.bashrc
fi
if ! grep -qF 'source ~/.bashrc_aliases' ~/.bashrc 2>/dev/null; then
    echo 'source ~/.bashrc_aliases' >> ~/.bashrc
fi
# Source bashrc only in interactive shells; non-interactive may lack shopt etc.
[[ $- == *i* ]] && source ~/.bashrc || true

run_step "mcp plugins" install_plugins

# --- Summary ---
echo ""
if [ ${#FAILURES[@]} -gt 0 ]; then
    echo "Setup complete with ${#FAILURES[@]} warning(s):"
    for f in "${FAILURES[@]}"; do
        echo "  - $f (optional)"
    done
    echo ""
    echo "Start a new tmux session or run: tmux source ~/.tmux.conf"
else
    echo "Setup complete! Start a new tmux session or run: tmux source ~/.tmux.conf"
fi
