#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

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

# Install glow (markdown renderer) if not present
if ! command -v glow &>/dev/null; then
    echo "Installing glow..."
    GLOW_VERSION="2.0.0"
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  GLOW_ARCH="x86_64" ;;
        aarch64) GLOW_ARCH="arm64"  ;;
        *)       echo "  Skipping glow (unsupported arch: $ARCH)"; GLOW_ARCH="" ;;
    esac
    if [ -n "$GLOW_ARCH" ]; then
        TMP="$(mktemp -d)"
        curl -sL "https://github.com/charmbracelet/glow/releases/download/v${GLOW_VERSION}/glow_${GLOW_VERSION}_Linux_${GLOW_ARCH}.tar.gz" \
            | tar xz -C "$TMP" --strip-components=1
        if [ -w /usr/local/bin ]; then
            mv "$TMP/glow" /usr/local/bin/glow
        else
            sudo mv "$TMP/glow" /usr/local/bin/glow
        fi
        rm -rf "$TMP"
        echo "  glow installed to /usr/local/bin/glow"
    fi
else
    echo "glow already installed: $(glow --version)"
fi

# Install Node.js (via nvm) if not present
if ! command -v node &>/dev/null; then
    echo "Installing Node.js via nvm..."
    export NVM_DIR="$HOME/.nvm"
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
    # shellcheck source=/dev/null
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    nvm install --lts
    echo "  Node $(node --version) installed"
else
    echo "Node.js already installed: $(node --version)"
fi

# Install uv (Python package manager) if not present
if ! command -v uv &>/dev/null; then
    echo "Installing uv..."
    UV_ARCH="$(uname -m)"
    TMP="$(mktemp -d)"
    curl -sL "https://github.com/astral-sh/uv/releases/latest/download/uv-${UV_ARCH}-unknown-linux-musl.tar.gz" \
        | tar xz -C "$TMP"
    mv "$TMP"/uv-*/uv "$TMP"/uv-*/uvx "$HOME/.local/bin/"
    rm -rf "$TMP"
    export PATH="$HOME/.local/bin:$PATH"
    echo "  uv $(uv --version) installed"
else
    echo "uv already installed: $(uv --version)"
fi

# Install CLI tools via apt (if available)
if command -v apt-get &>/dev/null; then
    PKGS=()
    command -v jq    &>/dev/null || PKGS+=(jq)
    command -v htop  &>/dev/null || PKGS+=(htop)
    if [ ${#PKGS[@]} -gt 0 ]; then
        echo "Installing apt packages: ${PKGS[*]}..."
        if [ -w /usr/bin ]; then
            apt-get update -qq && apt-get install -y -qq "${PKGS[@]}"
        else
            sudo apt-get update -qq && sudo apt-get install -y -qq "${PKGS[@]}"
        fi
    fi
fi

# Helper: install a binary from a GitHub release tarball
install_gh_binary() {
    local name="$1" url="$2" bin_name="${3:-$1}"
    if command -v "$bin_name" &>/dev/null; then
        echo "$bin_name already installed"
        return
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
        echo "  Warning: $bin_name binary not found in archive, skipping"
        rm -rf "$TMP"
        return
    fi
    chmod +x "$bin"
    if [ -w /usr/local/bin ]; then
        mv "$bin" /usr/local/bin/
    else
        sudo mv "$bin" /usr/local/bin/
    fi
    rm -rf "$TMP"
    echo "  $name installed to /usr/local/bin/$bin_name"
}

# Helper: install a .deb from a GitHub release
install_gh_deb() {
    local name="$1" url="$2"
    if command -v "$name" &>/dev/null; then
        echo "$name already installed"
        return
    fi
    echo "Installing $name..."
    TMP="$(mktemp -d)"
    curl -sL -o "$TMP/$name.deb" "$url"
    if [ -w /usr/bin ]; then
        dpkg -i "$TMP/$name.deb"
    else
        sudo dpkg -i "$TMP/$name.deb"
    fi
    rm -rf "$TMP"
    echo "  $name installed"
}

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  DEB_ARCH="amd64"; GH_ARCH="x86_64" ;;
    aarch64) DEB_ARCH="arm64"; GH_ARCH="aarch64" ;;
    *)       DEB_ARCH=""; GH_ARCH="" ;;
esac

if [ -n "$GH_ARCH" ]; then
    # fzf
    install_gh_binary fzf \
        "https://github.com/junegunn/fzf/releases/download/v0.62.0/fzf-0.62.0-linux_${DEB_ARCH}.tar.gz"

    # ripgrep
    install_gh_binary ripgrep \
        "https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-${GH_ARCH}-unknown-linux-musl.tar.gz" rg

    # fd
    install_gh_binary fd \
        "https://github.com/sharkdp/fd/releases/download/v10.2.0/fd-v10.2.0-${GH_ARCH}-unknown-linux-musl.tar.gz"

    # bat
    install_gh_deb bat \
        "https://github.com/sharkdp/bat/releases/download/v0.25.0/bat_0.25.0_${DEB_ARCH}.deb"

    # delta
    install_gh_deb delta \
        "https://github.com/dandavison/delta/releases/download/0.18.2/git-delta_0.18.2_${DEB_ARCH}.deb"

    # zoxide
    install_gh_binary zoxide \
        "https://github.com/ajeetdsouza/zoxide/releases/download/v0.9.6/zoxide-0.9.6-${GH_ARCH}-unknown-linux-musl.tar.gz"

    # lazygit
    LAZYGIT_ARCH="$GH_ARCH"
    [ "$LAZYGIT_ARCH" = "aarch64" ] && LAZYGIT_ARCH="arm64"
    install_gh_binary lazygit \
        "https://github.com/jesseduffield/lazygit/releases/download/v0.44.1/lazygit_0.44.1_Linux_${LAZYGIT_ARCH}.tar.gz"

    # btop
    install_gh_binary btop \
        "https://github.com/aristocratos/btop/releases/download/v1.4.0/btop-${GH_ARCH}-linux-musl.tbz" btop
else
    echo "Skipping binary installs (unsupported arch: $ARCH)"
fi

# Install Claude Code if not present
if ! command -v claude &>/dev/null; then
    echo "Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
    echo "  Run 'claude' to authenticate and get started."
else
    echo "Claude Code already installed: $(claude --version 2>&1 | head -1)"
fi

# Install OpenAI Codex CLI if not present
if ! command -v codex &>/dev/null; then
    if command -v npm &>/dev/null; then
        echo "Installing Codex CLI..."
        npm install -g @openai/codex
        echo "  Run 'codex' to get started."
    else
        echo "Skipping Codex CLI (npm not found — install Node.js first)"
    fi
else
    echo "Codex CLI already installed: $(codex --version 2>&1 | head -1)"
fi

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

# Install Claude Code MCP plugins (non-fatal if npx missing)
"$DIR/install_claude_plugins.sh" || echo "  Skipping MCP plugins (install Node.js and re-run)"

echo ""
echo "Done! Start a new tmux session or run: tmux source ~/.tmux.conf"
