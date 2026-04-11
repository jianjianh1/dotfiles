#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Error tracking ---
FAILURES=()

run_step() {
    local name="$1"; shift
    if ! "$@"; then
        FAILURES+=("$name")
    fi
}

# --- Helpers ---

# Symlink configs (back up existing files)
backup_and_link() {
    local src="$1" dst="$2"
    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        echo "  Backing up $dst -> ${dst}.bak"
        mv "$dst" "${dst}.bak"
    fi
    ln -sf "$src" "$dst"
    echo "  $src -> $dst"
}

# Wrapper: move/copy files respecting sudo needs
install_to() {
    local src="$1" dst="$2"
    if [ -n "$NEED_SUDO" ]; then
        sudo mv "$src" "$dst"
    else
        mv "$src" "$dst"
    fi
}

# Get latest release version from GitHub (strips leading 'v')
gh_latest() {
    curl -sI "https://github.com/$1/releases/latest" \
        | grep -i '^location:' | sed 's|.*/v\?\([^/[:space:]]*\).*|\1|'
}

# Install a binary from a GitHub release tarball
install_gh_binary() {
    local name="$1" url="$2" bin_name="${3:-$1}"
    if command -v "$bin_name" &>/dev/null; then
        echo "$bin_name already installed"
        return 0
    fi
    echo "Installing $name..."
    TMP="$(mktemp -d)"
    case "$url" in
        *.tbz|*.tar.bz2) curl -sL "$url" | tar xj -C "$TMP" ;;
        *)                curl -sL "$url" | tar xz -C "$TMP" ;;
    esac
    local bin
    bin="$(find "$TMP" -type f -name "$bin_name" | head -1)"
    if [ -z "$bin" ]; then
        echo "  Warning: $bin_name binary not found in archive"
        rm -rf "$TMP"
        return 1
    fi
    chmod +x "$bin"
    install_to "$bin" "$BIN_DIR/$bin_name"
    rm -rf "$TMP"
    echo "  $name installed to $BIN_DIR/$bin_name"
}

# Install a .deb from a GitHub release (extracts binary if no dpkg/sudo)
install_gh_deb() {
    local name="$1" url="$2"
    if command -v "$name" &>/dev/null; then
        echo "$name already installed"
        return 0
    fi
    echo "Installing $name..."
    TMP="$(mktemp -d)"
    curl -sL -o "$TMP/$name.deb" "$url"
    if [ -w /usr/bin ] || [ -n "$NEED_SUDO" ]; then
        if [ -n "$NEED_SUDO" ]; then
            sudo dpkg -i "$TMP/$name.deb"
        else
            dpkg -i "$TMP/$name.deb"
        fi
    else
        # No sudo — extract binary from .deb manually
        cd "$TMP"
        ar x "$name.deb"
        tar xf data.tar.* 2>/dev/null
        local bin
        bin="$(find "$TMP" -type f -name "$name" -path '*/bin/*' | head -1)"
        if [ -n "$bin" ]; then
            chmod +x "$bin"
            mv "$bin" "$BIN_DIR/$name"
        else
            echo "  Warning: $name binary not found in .deb"
            cd - >/dev/null
            rm -rf "$TMP"
            return 1
        fi
        cd - >/dev/null
    fi
    rm -rf "$TMP"
    echo "  $name installed"
}

# --- Install functions ---

install_glow() {
    if command -v glow &>/dev/null; then
        echo "glow already installed: $(glow --version)"
        return 0
    fi
    echo "Installing glow..."
    GLOW_VERSION="$(gh_latest charmbracelet/glow)"
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  GLOW_ARCH="x86_64" ;;
        aarch64) GLOW_ARCH="arm64"  ;;
        *)       echo "  Skipping glow (unsupported arch: $ARCH)"; return 1 ;;
    esac
    TMP="$(mktemp -d)"
    curl -sL "https://github.com/charmbracelet/glow/releases/download/v${GLOW_VERSION}/glow_${GLOW_VERSION}_Linux_${GLOW_ARCH}.tar.gz" \
        | tar xz -C "$TMP" --strip-components=1
    install_to "$TMP/glow" "$BIN_DIR/glow"
    rm -rf "$TMP"
    echo "  glow $GLOW_VERSION installed to $BIN_DIR/glow"
}

install_node() {
    if command -v node &>/dev/null; then
        echo "Node.js already installed: $(node --version)"
        return 0
    fi
    echo "Installing Node.js via nvm..."
    export NVM_DIR="$HOME/.nvm"
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
    # shellcheck source=/dev/null
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    nvm install --lts
    # Symlink node/npm/npx into ~/.local/bin so they're accessible outside nvm shells
    # (e.g. scripts with #!/usr/bin/env node shebangs)
    mkdir -p "$HOME/.local/bin"
    ln -sf "$(command -v node)" "$HOME/.local/bin/node"
    ln -sf "$(command -v npm)"  "$HOME/.local/bin/npm"
    ln -sf "$(command -v npx)"  "$HOME/.local/bin/npx"
    echo "  Node $(node --version) installed"
}

install_uv() {
    if command -v uv &>/dev/null; then
        echo "uv already installed: $(uv --version)"
        return 0
    fi
    echo "Installing uv..."
    UV_ARCH="$(uname -m)"
    TMP="$(mktemp -d)"
    curl -sL "https://github.com/astral-sh/uv/releases/latest/download/uv-${UV_ARCH}-unknown-linux-musl.tar.gz" \
        | tar xz -C "$TMP"
    mkdir -p "$HOME/.local/bin"
    mv "$TMP"/uv-*/uv "$TMP"/uv-*/uvx "$HOME/.local/bin/"
    rm -rf "$TMP"
    export PATH="$HOME/.local/bin:$PATH"
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
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  DEB_ARCH="amd64"; GH_ARCH="x86_64" ;;
        aarch64) DEB_ARCH="arm64"; GH_ARCH="aarch64" ;;
        *)       echo "Skipping binary installs (unsupported arch: $ARCH)"; return 0 ;;
    esac

    local V

    V="$(gh_latest junegunn/fzf)"
    run_step "fzf" install_gh_binary fzf \
        "https://github.com/junegunn/fzf/releases/download/v${V}/fzf-${V}-linux_${DEB_ARCH}.tar.gz"

    V="$(gh_latest BurntSushi/ripgrep)"
    run_step "ripgrep" install_gh_binary ripgrep \
        "https://github.com/BurntSushi/ripgrep/releases/download/${V}/ripgrep-${V}-${GH_ARCH}-unknown-linux-musl.tar.gz" rg

    V="$(gh_latest sharkdp/fd)"
    run_step "fd" install_gh_binary fd \
        "https://github.com/sharkdp/fd/releases/download/v${V}/fd-v${V}-${GH_ARCH}-unknown-linux-musl.tar.gz"

    V="$(gh_latest sharkdp/bat)"
    run_step "bat" install_gh_deb bat \
        "https://github.com/sharkdp/bat/releases/download/v${V}/bat_${V}_${DEB_ARCH}.deb"

    V="$(gh_latest dandavison/delta)"
    run_step "delta" install_gh_deb delta \
        "https://github.com/dandavison/delta/releases/download/${V}/git-delta_${V}_${DEB_ARCH}.deb"

    V="$(gh_latest ajeetdsouza/zoxide)"
    run_step "zoxide" install_gh_binary zoxide \
        "https://github.com/ajeetdsouza/zoxide/releases/download/v${V}/zoxide-${V}-${GH_ARCH}-unknown-linux-musl.tar.gz"

    LAZYGIT_ARCH="$GH_ARCH"
    [ "$LAZYGIT_ARCH" = "aarch64" ] && LAZYGIT_ARCH="arm64"
    V="$(gh_latest jesseduffield/lazygit)"
    run_step "lazygit" install_gh_binary lazygit \
        "https://github.com/jesseduffield/lazygit/releases/download/v${V}/lazygit_${V}_Linux_${LAZYGIT_ARCH}.tar.gz"

    V="$(gh_latest aristocratos/btop)"
    run_step "btop" install_gh_binary btop \
        "https://github.com/aristocratos/btop/releases/download/v${V}/btop-${GH_ARCH}-unknown-linux-musl.tbz" btop
}

install_claude() {
    if command -v claude &>/dev/null; then
        echo "Claude Code already installed: $(claude --version 2>&1 | head -1)"
        return 0
    fi
    echo "Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
    echo "  Run 'claude' to authenticate and get started."
}

install_codex() {
    if command -v codex &>/dev/null; then
        echo "Codex CLI already installed: $(codex --version 2>&1 | head -1)"
        return 0
    fi
    if ! command -v npm &>/dev/null; then
        echo "Skipping Codex CLI (npm not found — install Node.js first)"
        return 1
    fi
    echo "Installing Codex CLI..."
    if [ -n "$NEED_SUDO" ]; then
        sudo "$(command -v npm)" install -g @openai/codex
    elif [ -w "$(npm prefix -g)" ]; then
        npm install -g @openai/codex
    else
        npm install -g --prefix "$HOME/.local" @openai/codex
    fi
    echo "  Run 'codex' to get started."
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
if command -v gh &>/dev/null; then
    gh auth setup-git 2>/dev/null || true
fi
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
source ~/.bashrc

run_step "mcp plugins" install_plugins

# --- Summary ---
echo ""
if [ ${#FAILURES[@]} -gt 0 ]; then
    echo "Setup complete with ${#FAILURES[@]} failure(s):"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
    exit 1
else
    echo "Setup complete! Start a new tmux session or run: tmux source ~/.tmux.conf"
fi
