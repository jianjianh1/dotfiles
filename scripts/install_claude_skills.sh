#!/usr/bin/env bash
set -uo pipefail

# Install upstream Claude Code skills by cloning their repos to a cache
# directory under ~/.local/share/claude-skills/ and symlinking individual
# skills into ~/.claude/skills/ alongside the repo's custom skills.
#
# Mirrors install_claude_plugins.sh in spirit but does NOT touch MCP or the
# plugin marketplace — skills are pure markdown and CHPC-safe.

DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

FAILURES=()
FORCE=false
DRY_RUN=false

usage() {
    cat <<'EOF'
Usage: install_claude_skills.sh [--force] [--dry-run] [--help|-h]
  --force        Re-clone upstream repos even if already cached
  --dry-run      Show planned steps without changing files
  -h, --help     Show this help

Cache dir:   ~/.local/share/claude-skills/
Symlink dir: ~/.claude/skills/
EOF
}

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --dry-run|-n) DRY_RUN=true ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

CACHE_DIR="$HOME/.local/share/claude-skills"
SKILLS_DIR="$HOME/.claude/skills"

# --- Curated skill lists (canonical source of truth) -----------------------

SUPERPOWERS_REPO="https://github.com/obra/superpowers.git"
SUPERPOWERS_DIR="$CACHE_DIR/superpowers"
SUPERPOWERS_SKILLS=(
    systematic-debugging
    test-driven-development
    using-git-worktrees
    writing-plans
    executing-plans
    verification-before-completion
    brainstorming
    requesting-code-review
    receiving-code-review
    finishing-a-development-branch
    subagent-driven-development
    dispatching-parallel-agents
    writing-skills
)

ANTHROPIC_REPO="https://github.com/anthropics/skills.git"
ANTHROPIC_DIR="$CACHE_DIR/anthropic-skills"
# Pure markdown — safe everywhere.
ANTHROPIC_SKILLS_MARKDOWN=(
    skill-creator
    mcp-builder
    doc-coauthoring
    brand-guidelines
)
# Ship Python scripts that fetch deps ephemerally via `uv run --with <pkg>`.
# `uv` is installed by the main install.sh; nothing to install here.
ANTHROPIC_SKILLS_PYDEPS=(
    pdf
    xlsx
    docx
    pptx
)

# --- Operations ------------------------------------------------------------

# Shallow-clone $1 into $2, or `git -C $2 pull --ff-only` if it already
# exists. With --force, blow it away and re-clone fresh.
clone_or_update() {
    local repo="$1" dest="$2"
    if [ "$DRY_RUN" = true ]; then
        echo "[dry-run] Would clone or update $repo into $dest"
        return 0
    fi
    if [ "$FORCE" = true ] && [ -d "$dest" ]; then
        echo "  Removing existing clone: $dest"
        rm -rf "$dest"
    fi
    if [ -d "$dest/.git" ]; then
        echo "  Updating clone: $dest"
        retry git -C "$dest" pull --ff-only --quiet || return 1
    else
        echo "  Cloning $repo -> $dest"
        mkdir -p "$(dirname "$dest")" || return 1
        retry git clone --depth=1 --quiet "$repo" "$dest" || return 1
    fi
}

# Symlink $cache/skills/$name into ~/.claude/skills/$name.
# Logs and continues (does not fail) if the upstream skill no longer exists
# in the clone — keeps the curated lists tolerant to upstream renames.
link_skill() {
    local cache_root="$1" name="$2"
    local src="$cache_root/skills/$name"
    local dst="$SKILLS_DIR/$name"

    if [ "$DRY_RUN" = true ]; then
        echo "[dry-run] Would symlink $src -> $dst"
        return 0
    fi

    if [ ! -d "$src" ] || [ ! -f "$src/SKILL.md" ]; then
        echo "  Skipping $name — not present in $(display_path_local "$cache_root")"
        return 0
    fi

    # Refuse to clobber a non-managed symlink or a real directory (would
    # happen if the user manually added a skill of the same name).
    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        echo "  Skipping $name — $dst exists and is not a symlink"
        return 0
    fi
    if [ -L "$dst" ]; then
        local current src_canon cache_canon
        current="$(portable_realpath "$dst" 2>/dev/null || true)"
        # On macOS, portable_realpath resolves /var → /private/var while $src
        # and $CACHE_DIR stay logical. Match both forms so re-runs of an
        # already-correct symlink don't get flagged as "outside the cache".
        src_canon="$(portable_realpath "$src" 2>/dev/null || printf '%s' "$src")"
        cache_canon="$(portable_realpath "$CACHE_DIR" 2>/dev/null || printf '%s' "$CACHE_DIR")"
        case "$current" in
            "$src"|"$src_canon")
                # Already correctly linked. Skip — and crucially do not call
                # backup_and_link, which would back up to .bak because its own
                # equality check compares the canonicalized target to the
                # logical $src on macOS.
                return 0
                ;;
            "$CACHE_DIR"/*|"$cache_canon"/*) ;;  # ours, repointing within the cache is OK
            *)
                # Points outside our cache (e.g. into a different dotfiles
                # repo or into ai/skills). Leave it alone.
                echo "  Skipping $name — $dst points outside the upstream cache"
                return 0
                ;;
        esac
    fi

    backup_and_link "$src" "$dst"
}

# Pretty-print a path with $HOME collapsed to ~ (output-only; the ~ is a
# literal character, not a shell tilde-expansion).
display_path_local() {
    local path="$1" tilde='~'
    case "$path" in
        "$HOME") printf '%s' "$tilde" ;;
        "$HOME"/*) printf '%s/%s' "$tilde" "${path#"$HOME"/}" ;;
        *) printf '%s' "$path" ;;
    esac
}

main() {
    if ! command -v git &>/dev/null; then
        echo "Error: git not found. Install git first." >&2
        exit 1
    fi

    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$CACHE_DIR" "$SKILLS_DIR" || exit 1
    fi

    echo "Installing upstream Claude Code skills..."
    echo "  Cache:    $(display_path_local "$CACHE_DIR")"
    echo "  Symlinks: $(display_path_local "$SKILLS_DIR")"
    echo ""

    # --- obra/superpowers ---
    run_step "clone superpowers" clone_or_update "$SUPERPOWERS_REPO" "$SUPERPOWERS_DIR"
    for name in "${SUPERPOWERS_SKILLS[@]}"; do
        run_step "link superpowers:$name" link_skill "$SUPERPOWERS_DIR" "$name"
    done

    # --- anthropics/skills (markdown-only) ---
    run_step "clone anthropic-skills" clone_or_update "$ANTHROPIC_REPO" "$ANTHROPIC_DIR"
    for name in "${ANTHROPIC_SKILLS_MARKDOWN[@]}"; do
        run_step "link anthropic:$name" link_skill "$ANTHROPIC_DIR" "$name"
    done

    # --- anthropics/skills (document creators; uv handles deps on demand) ---
    for name in "${ANTHROPIC_SKILLS_PYDEPS[@]}"; do
        run_step "link anthropic:$name" link_skill "$ANTHROPIC_DIR" "$name"
    done

    echo ""
    if [ ${#FAILURES[@]} -gt 0 ]; then
        echo "Done with ${#FAILURES[@]} warning(s):"
        for f in "${FAILURES[@]}"; do
            echo "  - $f (non-critical)"
        done
        exit 0
    fi
    echo "Done — all upstream skills installed."
}

main "$@"
