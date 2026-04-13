#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
YES=false

for arg in "$@"; do
    case "$arg" in
        -y|--yes) YES=true ;;
        -h|--help)
            echo "Usage: uninstall.sh [--yes|-y] [--help|-h]"
            echo "  -y, --yes                 Skip confirmation prompts"
            echo "  -h, --help                Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run './uninstall.sh --help' for usage."
            exit 1
            ;;
    esac
done

# --- Helpers ---

confirm() {
    if $YES; then return 0; fi
    read -rp "$1 [y/N] " ans
    [[ "$ans" =~ ^[Yy] ]]
}

# Remove a symlink only if it points into this repo, then restore .bak if present
restore_backup() {
    local dst="$1"
    if [ -e "${dst}.bak" ]; then
        mv "${dst}.bak" "$dst"
        echo "  Restored ${dst}.bak -> $dst"
    fi
}

unlink_config() {
    local dst="$1"
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        rm -rf "$dst"
        echo "  Removed $dst"
        restore_backup "$dst"
    else
        echo "  Skipped $dst (not present)"
    fi
}

remove_path() {
    local path="$1" label="${2:-$1}"
    if [ -e "$path" ] || [ -L "$path" ]; then
        rm -rf "$path"
        echo "  Removed $label"
    fi
}

remove_dir_if_empty() {
    local path="$1" label="${2:-$1}"
    if [ -d "$path" ]; then
        rmdir "$path" 2>/dev/null && echo "  Removed $label"
    fi
}

clean_line_from_file() {
    local file="$1" pattern="$2"
    if [ -f "$file" ]; then
        sed -i "\|$pattern|d" "$file"
        echo "  Cleaned $file"
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
    echo "Removing shell init lines..."
    clean_line_from_file "$HOME/.bashrc" '^source ~/.bashrc_exports$'
    clean_line_from_file "$HOME/.bashrc" '^source ~/.bashrc_aliases$'
    clean_line_from_file "$HOME/.bashrc" '^\[ -f ~/.env_keys \] && . ~/.env_keys$'
    clean_line_from_file "$HOME/.profile" '^\[ -f ~/.env_keys \] && . ~/.env_keys$'
}

remove_tools() {
    echo "Removing CLI tools..."
    for bin in gh glow fzf rg fd bat delta zoxide lazygit btop jq uv uvx; do
        remove_bin "$bin"
    done
}

remove_claude() {
    echo "Removing Claude Code..."
    if command -v claude &>/dev/null; then
        claude --uninstall 2>/dev/null || npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
    fi

    remove_bin claude
    remove_path "$HOME/.claude" "~/.claude"
    remove_path "$HOME/.claude.json" "~/.claude.json"
    remove_path "$HOME/.local/share/claude" "~/.local/share/claude"
    remove_path "$HOME/.cache/claude" "~/.cache/claude"
    remove_path "$HOME/.config/claude" "~/.config/claude"
}

remove_codex() {
    echo "Removing Codex CLI..."
    if command -v codex &>/dev/null; then
        # Clean up legacy npm install if present
        npm uninstall -g @openai/codex 2>/dev/null || true
    fi

    remove_bin codex
    remove_path "$HOME/.codex" "~/.codex"
    remove_path "$HOME/.local/share/codex" "~/.local/share/codex"
    remove_path "$HOME/.cache/codex" "~/.cache/codex"
}

remove_node() {
    echo "Removing Node.js..."
    # Remove node/npm/npx installed to ~/.local by setup.sh
    for bin in node npm npx corepack; do
        remove_bin "$bin"
    done
    remove_path "$HOME/.local/lib/node_modules" "~/.local/lib/node_modules"
    remove_path "$HOME/.local/include/node" "~/.local/include/node"
    remove_path "$HOME/.local/share/doc/node" "~/.local/share/doc/node"
    remove_path "$HOME/.local/share/man/man1/node.1" "~/.local/share/man/man1/node.1"
    remove_path "$HOME/.local/share/systemtap/tapset/node.stp" "~/.local/share/systemtap/tapset/node.stp"
    # Also clean up nvm if present from an older install
    remove_path "$HOME/.nvm" "~/.nvm"
}

remove_dirs() {
    echo "Cleaning up directories..."
    remove_dir_if_empty "$HOME/.vim/undodir" "~/.vim/undodir"
    remove_dir_if_empty "$HOME/.vim" "~/.vim"
    remove_dir_if_empty "$HOME/.ssh/sockets" "~/.ssh/sockets"
    remove_dir_if_empty "$HOME/.claude" "~/.claude"
    remove_dir_if_empty "$HOME/.codex" "~/.codex"
    remove_dir_if_empty "$HOME/.local/share/man/man1" "~/.local/share/man/man1"
    remove_dir_if_empty "$HOME/.local/share/man" "~/.local/share/man"
    remove_dir_if_empty "$HOME/.local/share/doc" "~/.local/share/doc"
    remove_dir_if_empty "$HOME/.local/share/systemtap/tapset" "~/.local/share/systemtap/tapset"
    remove_dir_if_empty "$HOME/.local/share/systemtap" "~/.local/share/systemtap"
    remove_dir_if_empty "$HOME/.local/share/claude" "~/.local/share/claude"
    remove_dir_if_empty "$HOME/.local/share/codex" "~/.local/share/codex"
    remove_dir_if_empty "$HOME/.local/share" "~/.local/share"
    remove_dir_if_empty "$HOME/.local/include" "~/.local/include"
    remove_dir_if_empty "$HOME/.local/lib" "~/.local/lib"
    remove_dir_if_empty "$HOME/.local/bin" "~/.local/bin"
    remove_dir_if_empty "$HOME/.local" "~/.local"
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
