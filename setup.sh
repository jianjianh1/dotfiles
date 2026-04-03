#!/usr/bin/env bash
set -euo pipefail

REPO="jianjianh1/server-configs"
DIR="$HOME/.server-configs"

# Clone the repo (requires gh auth login)
if [ -d "$DIR" ]; then
    echo "Updating $DIR..."
    git -C "$DIR" pull --ff-only
else
    echo "Cloning $REPO..."
    gh repo clone "$REPO" "$DIR"
fi

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

# Install Claude Code if not present
if ! command -v claude &>/dev/null; then
    echo "Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | sh
    echo "  Run 'claude' to authenticate and get started."
else
    echo "Claude Code already installed: $(claude --version 2>&1 | head -1)"
fi

echo ""
echo "Done! Start a new tmux session or run: tmux source ~/.tmux.conf"
