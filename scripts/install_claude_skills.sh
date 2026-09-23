#!/usr/bin/env bash
set -uo pipefail

# Install upstream Claude Code skills by cloning their repos to a cache
# directory under ~/.local/share/claude-skills/ and symlinking individual
# skills into ~/.claude/skills/ alongside the repo's custom skills.
#
# Upstream repos: obra/superpowers and anthropics/skills (multi-skill layout
# <clone>/skills/<name>/), Master-cai/Research-Paper-Writing-Skills (one skill
# in a named subdir), stephenturner/skill-deslop (SKILL.md at the clone root),
# mattpocock/skills and radarist/structured-analytic-skills (named subdirs).
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
Upstream:    obra/superpowers, anthropics/skills,
             Master-cai/Research-Paper-Writing-Skills, stephenturner/skill-deslop,
             mattpocock/skills, radarist/structured-analytic-skills
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
SKILLS_DIR="$CLAUDE_SKILLS_DIR"      # from lib/common.sh
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

# Single-skill repos. The first arg to link_skill_path is the directory that
# holds SKILL.md — a named subdir for Research-Paper-Writing-Skills, the clone
# root for skill-deslop. Both MIT.
RPW_REPO="https://github.com/Master-cai/Research-Paper-Writing-Skills.git"
RPW_DIR="$CACHE_DIR/research-paper-writing-skills"
RPW_SKILL_NAME="research-paper-writing"
RPW_SKILL_SRC="$RPW_DIR/research-paper-writing"   # SKILL.md + references/ + agents/openai.yaml

DESLOP_REPO="https://github.com/stephenturner/skill-deslop.git"
DESLOP_DIR="$CACHE_DIR/skill-deslop"
DESLOP_SKILL_NAME="deslop"
DESLOP_SKILL_SRC="$DESLOP_DIR"                    # SKILL.md at the repo root

GRILLING_REPO="https://github.com/mattpocock/skills.git"
GRILLING_DIR="$CACHE_DIR/mattpocock-skills"
GRILLING_SKILL_NAME="grilling"
GRILLING_SKILL_SRC="$GRILLING_DIR/skills/productivity/grilling"

PREMORTEM_REPO="https://github.com/radarist/structured-analytic-skills.git"
PREMORTEM_DIR="$CACHE_DIR/structured-analytic-skills"
PREMORTEM_SKILL_NAME="premortem-analysis"
PREMORTEM_SKILL_SRC="$PREMORTEM_DIR/skills/premortem-analysis"

# --- Operations ------------------------------------------------------------

# All upstream skill <name>s the curated lists own. Used by prune_orphans()
# to decide whether a stray symlink in ~/.claude/skills/ should be removed.
kept_skill_names() {
    printf '%s\n' "${SUPERPOWERS_SKILLS[@]}" \
                 "${ANTHROPIC_SKILLS_MARKDOWN[@]}" \
                 "${ANTHROPIC_SKILLS_PYDEPS[@]}" \
                 "$RPW_SKILL_NAME" "$DESLOP_SKILL_NAME" \
                 "$GRILLING_SKILL_NAME" "$PREMORTEM_SKILL_NAME"
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

# Link one skill directory into ~/.claude/skills/<name>. $src must hold
# SKILL.md and live under $CACHE_DIR; the repo layout is the caller's concern.
# Logs and continues (does not fail) when an upstream skill no longer
# exists in the clone — keeps the curated lists tolerant to upstream renames.
link_skill_path() {
    local src="$1" name="$2"
    local dst="$SKILLS_DIR/$name"

    if [ "$DRY_RUN" = true ]; then
        echo "[dry-run] Would symlink $src -> $dst"
        return 0
    fi

    if [ ! -d "$src" ] || [ ! -f "$src/SKILL.md" ]; then
        echo "  Skipping $name — no SKILL.md at $(display_path "$src")"
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

# Conventional multi-skill layout <clone>/skills/<name>/SKILL.md
# (obra/superpowers, anthropics/skills).
link_skill() {
    link_skill_path "$1/skills/$2" "$2"
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

    # --- Master-cai/Research-Paper-Writing-Skills (one skill, in a subdir) ---
    run_step "clone research-paper-writing-skills" clone_or_update "$RPW_REPO" "$RPW_DIR"
    run_step "link $RPW_SKILL_NAME" link_skill_path "$RPW_SKILL_SRC" "$RPW_SKILL_NAME"

    # --- stephenturner/skill-deslop (SKILL.md at the repo root) ---
    run_step "clone skill-deslop" clone_or_update "$DESLOP_REPO" "$DESLOP_DIR"
    run_step "link $DESLOP_SKILL_NAME" link_skill_path "$DESLOP_SKILL_SRC" "$DESLOP_SKILL_NAME"

    # --- mattpocock/skills (engine for the bundled grill-me entry point) ---
    run_step "clone mattpocock-skills" clone_or_update "$GRILLING_REPO" "$GRILLING_DIR"
    run_step "link $GRILLING_SKILL_NAME" link_skill_path "$GRILLING_SKILL_SRC" "$GRILLING_SKILL_NAME"

    # --- radarist/structured-analytic-skills (concrete-plan critique) ---
    run_step "clone structured-analytic-skills" clone_or_update "$PREMORTEM_REPO" "$PREMORTEM_DIR"
    run_step "link $PREMORTEM_SKILL_NAME" link_skill_path "$PREMORTEM_SKILL_SRC" "$PREMORTEM_SKILL_NAME"

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
