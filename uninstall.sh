#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
YES=false
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=true

# --- Helpers ---

confirm() {
    if $YES; then return 0; fi
    read -rp "$1 [y/N] " ans
    [[ "$ans" =~ ^[Yy] ]]
}

# Remove a symlink only if it points into this repo, then restore .bak if present
unlink_config() {
    local dst="$1"
    if [ -L "$dst" ] && [[ "$(readlink -f "$dst")" == "$DIR"/* ]]; then
        rm "$dst"
        echo "  Removed $dst"
        if [ -e "${dst}.bak" ]; then
            mv "${dst}.bak" "$dst"
            echo "  Restored ${dst}.bak -> $dst"
        fi
    elif [ -L "$dst" ]; then
        echo "  Skipped $dst (symlink points elsewhere)"
    else
        echo "  Skipped $dst (not a symlink to this repo)"
    fi
}

remove_bin() {
    local bin="$1"
    if [ -e "$HOME/.local/bin/$bin" ]; then
        rm "$HOME/.local/bin/$bin"
        echo "  Removed ~/.local/bin/$bin"
    fi
    if [ -e "/usr/local/bin/$bin" ]; then
        if [ -w /usr/local/bin ] || { command -v sudo &>/dev/null && sudo -n true 2>/dev/null; }; then
            if [ -w /usr/local/bin ]; then
                rm "/usr/local/bin/$bin"
            else
                sudo rm "/usr/local/bin/$bin"
            fi
            echo "  Removed /usr/local/bin/$bin"
        else
            echo "  Found /usr/local/bin/$bin but need sudo to remove"
        fi
    fi
}

# --- Uninstall steps ---

remove_symlinks() {
    echo "Removing config symlinks..."
    unlink_config "$HOME/.vimrc"
    unlink_config "$HOME/.tmux.conf"
    unlink_config "$HOME/.gitconfig"
    unlink_config "$HOME/.inputrc"
    unlink_config "$HOME/.dircolors"
    unlink_config "$HOME/.ssh/config"
    unlink_config "$HOME/.bashrc_exports"
    unlink_config "$HOME/.bashrc_aliases"
    unlink_config "$HOME/.claude/settings.json"
    unlink_config "$HOME/.codex/config.toml"
}

remove_bashrc_lines() {
    echo "Removing source lines from ~/.bashrc..."
    if [ -f "$HOME/.bashrc" ]; then
        sed -i '/^source ~\/.bashrc_exports$/d' "$HOME/.bashrc"
        sed -i '/^source ~\/.bashrc_aliases$/d' "$HOME/.bashrc"
        echo "  Cleaned ~/.bashrc"
    fi
}

remove_tools() {
    echo "Removing CLI tools..."
    for bin in glow fzf rg fd bat delta zoxide lazygit btop uv uvx node npm npx; do
        remove_bin "$bin"
    done
}

remove_claude() {
    if command -v claude &>/dev/null; then
        echo "Uninstalling Claude Code..."
        claude --uninstall 2>/dev/null || npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
        echo "  Claude Code removed"
    else
        echo "  Claude Code not installed, skipping"
    fi
}

remove_codex() {
    if command -v codex &>/dev/null; then
        echo "Uninstalling Codex CLI..."
        npm uninstall -g @openai/codex 2>/dev/null || true
        echo "  Codex CLI removed"
    else
        echo "  Codex CLI not installed, skipping"
    fi
}

remove_node() {
    # Remove node/npm/npx installed to ~/.local by setup.sh
    for bin in node npm npx corepack; do
        remove_bin "$bin"
    done
    if [ -d "$HOME/.local/lib/node_modules" ]; then
        rm -rf "$HOME/.local/lib/node_modules"
        echo "  Removed ~/.local/lib/node_modules"
    fi
    if [ -d "$HOME/.local/include/node" ]; then
        rm -rf "$HOME/.local/include/node"
        echo "  Removed ~/.local/include/node"
    fi
    # Also clean up nvm if present from an older install
    if [ -d "$HOME/.nvm" ]; then
        rm -rf "$HOME/.nvm"
        echo "  Removed ~/.nvm"
    fi
}

remove_dirs() {
    echo "Cleaning up directories..."
    rmdir "$HOME/.vim/undodir" 2>/dev/null && echo "  Removed ~/.vim/undodir" || true
    rmdir "$HOME/.vim" 2>/dev/null && echo "  Removed ~/.vim" || true
    if [ -d "$HOME/.codex" ] && [ -z "$(ls -A "$HOME/.codex")" ]; then
        rmdir "$HOME/.codex"
        echo "  Removed ~/.codex"
    fi
}

# ============================================================
# Main
# ============================================================

echo "server-configs uninstaller"
echo "========================="
echo ""

confirm "Remove config symlinks?" && remove_symlinks
echo ""
confirm "Remove source lines from ~/.bashrc?" && remove_bashrc_lines
echo ""
confirm "Uninstall Claude Code?" && remove_claude
echo ""
confirm "Uninstall Codex CLI?" && remove_codex
echo ""
confirm "Remove Node.js?" && remove_node
echo ""
confirm "Remove CLI tools from ~/.local/bin?" && remove_tools
echo ""
confirm "Clean up empty directories?" && remove_dirs

echo ""
echo "Uninstall complete. Open a new shell to pick up changes."
