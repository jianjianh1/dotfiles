#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATED_DIR="$HOME/.server-configs-generated"
INSTALL_MANIFEST="$GENERATED_DIR/install-manifest.txt"
YES=false

# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

# --- Helpers ---

display_path() {
    local path="$1"

    case "$path" in
        "$HOME") printf "~" ;;
        "$HOME"/*) printf "%s/%s" "~" "${path#"$HOME"/}" ;;
        *) printf "%s" "$path" ;;
    esac
}

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
    local target=""

    if [ -L "$dst" ]; then
        target="$(portable_realpath "$dst" 2>/dev/null || true)"
        case "$target" in
            "$DIR"|"$DIR"/*)
                rm -f "$dst"
                echo "  Removed $dst"
                restore_backup "$dst"
                ;;
            *)
                echo "  Skipped $dst (not managed by this repo)"
                ;;
        esac
        return
    fi

    if [ -e "$dst" ]; then
        echo "  Skipped $dst (not a repo-managed symlink)"
    else
        echo "  Skipped $dst (not present)"
    fi
}

remove_path() {
    local path="$1" label="${2:-}"
    label="${label:-$(display_path "$path")}"
    if [ -e "$path" ] || [ -L "$path" ]; then
        rm -rf "$path"
        echo "  Removed $label"
    fi
}

remove_tracked_path() {
    local path="$1" label="${2:-}"
    label="${label:-$(display_path "$path")}"

    if ! manifest_contains_path "$path"; then
        if [ -e "$path" ] || [ -L "$path" ]; then
            echo "  Skipped $label (not tracked by setup.sh)"
        fi
        return 0
    fi

    if [ -e "$path" ] || [ -L "$path" ]; then
        rm -rf "$path"
        echo "  Removed $label"
    fi
}

remove_dir_if_empty() {
    local path="$1" label="${2:-}"
    label="${label:-$(display_path "$path")}"
    if [ -d "$path" ]; then
        rmdir "$path" 2>/dev/null && echo "  Removed $label"
    fi
}

clean_line_from_file() {
    local file="$1" pattern="$2"
    if [ -f "$file" ]; then
        delete_matching_lines "$file" "$pattern" || return 1
        echo "  Cleaned $file"
    fi
}

remove_bin() {
    local bin="$1"
    if manifest_contains_path "$HOME/.local/bin/$bin"; then
        if [ -e "$HOME/.local/bin/$bin" ]; then
            rm "$HOME/.local/bin/$bin"
            echo "  Removed ~/.local/bin/$bin"
        fi
    elif [ -e "$HOME/.local/bin/$bin" ]; then
        echo "  Skipped ~/.local/bin/$bin (not tracked by setup.sh)"
    fi

    if manifest_contains_path "/usr/local/bin/$bin"; then
        if [ ! -e "/usr/local/bin/$bin" ]; then
            return 0
        fi
        if is_macos; then
            echo "  Skipped /usr/local/bin/$bin (managed by system package manager on macOS)"
            return 0
        fi
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
    elif [ -e "/usr/local/bin/$bin" ]; then
        echo "  Skipped /usr/local/bin/$bin (not tracked by setup.sh)"
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
    unlink_config "$HOME/.config/nvim"
    unlink_config "$HOME/.config/starship.toml"
    unlink_config "$HOME/.config/tmux/tmux.conf"
    unlink_config "$HOME/.bashrc_exports"
    unlink_config "$HOME/.bashrc_aliases"
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
    for bin in gh glow fzf rg fd bat delta zoxide lazygit btop jq uv uvx starship atuin chpc-allocs; do
        remove_bin "$bin"
    done
}

remove_claude() {
    echo "Removing Claude Code..."
    remove_bin claude
    remove_tracked_path "$HOME/.claude/settings.json"
    remove_dir_if_empty "$HOME/.claude"
}

remove_codex() {
    echo "Removing Codex CLI..."
    remove_bin codex
    remove_tracked_path "$HOME/.codex/config.toml"
    remove_dir_if_empty "$HOME/.codex"
}

remove_nvim() {
    echo "Removing Neovim..."
    remove_bin nvim
    remove_tracked_path "$HOME/.local/opt/nvim"
}

remove_node() {
    echo "Removing Node.js..."
    for bin in node npm npx corepack; do
        remove_bin "$bin"
    done
    remove_tracked_path "$HOME/.local/lib/node_modules"
    remove_tracked_path "$HOME/.local/include/node"
    remove_tracked_path "$HOME/.local/share/doc/node"
    remove_tracked_path "$HOME/.local/share/man/man1/node.1"
    remove_tracked_path "$HOME/.local/share/systemtap/tapset/node.stp"
}

remove_dirs() {
    echo "Cleaning up directories..."
    remove_path "$HOME/.server-configs-generated"
    remove_path "$HOME/.tmux/plugins"
    remove_dir_if_empty "$HOME/.tmux"
    remove_dir_if_empty "$HOME/.config/tmux"
    remove_dir_if_empty "$HOME/.vim/undodir"
    remove_dir_if_empty "$HOME/.vim"
    remove_dir_if_empty "$HOME/.ssh/sockets"
    remove_dir_if_empty "$HOME/.claude"
    remove_dir_if_empty "$HOME/.codex"
    remove_dir_if_empty "$HOME/.local/share/man/man1"
    remove_dir_if_empty "$HOME/.local/share/man"
    remove_dir_if_empty "$HOME/.local/share/doc"
    remove_dir_if_empty "$HOME/.local/share/systemtap/tapset"
    remove_dir_if_empty "$HOME/.local/share/systemtap"
    remove_dir_if_empty "$HOME/.local/share/claude"
    remove_dir_if_empty "$HOME/.local/share/codex"
    remove_dir_if_empty "$HOME/.local/share"
    remove_dir_if_empty "$HOME/.local/include"
    remove_dir_if_empty "$HOME/.local/opt"
    remove_dir_if_empty "$HOME/.local/lib"
    remove_dir_if_empty "$HOME/.local/bin"
    remove_dir_if_empty "$HOME/.local"
}

parse_args() {
    local arg

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
}

main() {
    parse_args "$@"

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
    confirm "Remove Neovim?" && remove_nvim
    echo ""
    confirm "Remove Node.js?" && remove_node
    echo ""
    confirm "Remove CLI tools from ~/.local/bin?" && remove_tools
    echo ""
    confirm "Clean up empty directories?" && remove_dirs

    echo ""
    echo "Uninstall complete. Open a new shell to pick up changes."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
