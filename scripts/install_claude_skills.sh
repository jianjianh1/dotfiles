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

CACHE_DIR="$EXTERNAL_SKILLS_CACHE"   # from lib/common.sh
SKILLS_DIR="$HOME/.claude/skills"
CACHE_CANON=""                       # filled in main() after mkdir

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
)

# --- Operations ------------------------------------------------------------

# All upstream skill <name>s the curated lists own. Used by prune_orphans()
# to decide whether a stray symlink in ~/.claude/skills/ should be removed.
kept_skill_names() {
    printf '%s\n' "${SUPERPOWERS_SKILLS[@]}" \
                 "${ANTHROPIC_SKILLS_MARKDOWN[@]}" \
                 "${ANTHROPIC_SKILLS_PYDEPS[@]}"
}

# Remove ~/.claude/skills/<name> symlinks that point into the upstream
# clone cache but whose <name> is no longer in our curated lists. Only
# touches symlinks (never directories or regular files) and only those
# resolving under $CACHE_DIR — user-added skills and bundled repo skills
# are left alone.
prune_orphans() {
    [ -d "$SKILLS_DIR" ] || return 0
    local link name target kept
    kept="$(kept_skill_names)"
    for link in "$SKILLS_DIR"/*; do
        [ -L "$link" ] || continue
        target="$(portable_realpath "$link" 2>/dev/null || true)"
        # Broken symlinks (cache directory deleted manually) defeat
        # portable_realpath; fall back to the literal link target so we
        # still classify them as cache orphans and clean them up.
        [ -n "$target" ] || target="$(readlink "$link" 2>/dev/null || true)"
        case "$target" in
            "$CACHE_DIR"/*|"$CACHE_CANON"/*) ;;
            *) continue ;;
        esac
        name="$(basename "$link")"
        if ! printf '%s\n' "$kept" | grep -Fxq "$name"; then
            if [ "$DRY_RUN" = true ]; then
                echo "[dry-run] Would unlink orphan $link"
            else
                rm -f "$link"
                echo "  Pruned orphan symlink: $name"
            fi
        fi
    done
}

# Skip `git pull` if the clone was refreshed within this window. Bounded
# so `./install.sh` stays cheap to re-run; `--force` always re-clones.
CACHE_FRESH_HOURS=24

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
        local fetch_head="$dest/.git/FETCH_HEAD"
        if [ -f "$fetch_head" ] && \
           [ -n "$(find "$fetch_head" -mmin "-$((CACHE_FRESH_HOURS * 60))" 2>/dev/null)" ]; then
            echo "  Up to date (cached): $dest"
            return 0
        fi
        echo "  Updating clone: $dest"
        retry git -C "$dest" pull --ff-only --quiet || return 1
        touch "$fetch_head" 2>/dev/null || true
    else
        echo "  Cloning $repo -> $dest"
        mkdir -p "$(dirname "$dest")" || return 1
        retry git clone --depth=1 --quiet "$repo" "$dest" || return 1
        # `git clone` doesn't create FETCH_HEAD; touch it so the next run
        # hits the freshness gate instead of running a no-op pull.
        touch "$dest/.git/FETCH_HEAD" 2>/dev/null || true
    fi
}

# Logs and continues (does not fail) when an upstream skill no longer
# exists in the clone — keeps the curated lists tolerant to upstream renames.
link_skill() {
    local cache_root="$1" name="$2"
    local src="$cache_root/skills/$name"
    local dst="$SKILLS_DIR/$name"

    if [ "$DRY_RUN" = true ]; then
        echo "[dry-run] Would symlink $src -> $dst"
        return 0
    fi

    if [ ! -d "$src" ] || [ ! -f "$src/SKILL.md" ]; then
        echo "  Skipping $name — not present in $(display_path "$cache_root")"
        return 0
    fi

    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        echo "  Skipping $name — $dst exists and is not a symlink"
        return 0
    fi
    if [ -L "$dst" ]; then
        local current src_canon
        current="$(portable_realpath "$dst" 2>/dev/null || true)"
        src_canon="$(portable_realpath "$src" 2>/dev/null || printf '%s' "$src")"
        case "$current" in
            "$src"|"$src_canon")
                # Already correctly linked. Returning here is load-bearing:
                # backup_and_link compares its canonicalized target to the
                # logical $src and would otherwise create a spurious .bak on
                # macOS (where /var → /private/var).
                return 0
                ;;
            "$CACHE_DIR"/*|"$CACHE_CANON"/*) ;;
            *)
                echo "  Skipping $name — $dst points outside the upstream cache"
                return 0
                ;;
        esac
    fi

    backup_and_link "$src" "$dst"
}

main() {
    if ! command -v git &>/dev/null; then
        echo "Error: git not found. Install git first." >&2
        exit 1
    fi

    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$CACHE_DIR" "$SKILLS_DIR" || exit 1
    fi
    CACHE_CANON="$(portable_realpath "$CACHE_DIR" 2>/dev/null || printf '%s' "$CACHE_DIR")"

    echo "Installing upstream Claude Code skills..."
    echo "  Cache:    $(display_path "$CACHE_DIR")"
    echo "  Symlinks: $(display_path "$SKILLS_DIR")"
    echo ""

    prune_orphans

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
