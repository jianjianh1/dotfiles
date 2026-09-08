#!/usr/bin/env bash
set -uo pipefail

# Mirror skills between Claude Code and Codex CLI with per-skill symlinks:
#
#   A. Claude -> Codex: every ~/.claude/skills/<name>/SKILL.md (bundled
#      ai/skills, upstream clones, user-added) gets ~/.agents/skills/<name>
#      -> the *resolved* skill directory. Codex reads ~/.agents/skills.
#   B. Codex -> Claude: every real ~/.codex/skills/<name>/SKILL.md (where
#      Codex's $skill-installer writes; .system/ excluded) gets
#      ~/.claude/skills/<name> -> that directory.
#
# Never replaces a real directory or a symlink that points elsewhere. Removes
# only *broken* links whose target is under a root this repo manages. Uninstall
# is a root sweep (uninstall.sh::unlink_agent_skills), not the install
# manifest, because this script also runs standalone.

DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

FAILURES=()
DRY_RUN=false

usage() {
    cat <<'USAGE'
Usage: sync_agent_skills.sh [--dry-run|-n] [--help|-h]
  -n, --dry-run  Show planned links without changing files
  -h, --help     Show this help

~/.claude/skills/<name>  ->  ~/.agents/skills/<name>   (Claude -> Codex)
~/.codex/skills/<name>   ->  ~/.claude/skills/<name>   (Codex  -> Claude)
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=true ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Roots come from lib/common.sh (CLAUDE_SKILLS_DIR, CODEX_AGENT_SKILLS_DIR,
# CODEX_HOME_SKILLS_DIR, EXTERNAL_SKILLS_CACHE). Canonical twins are filled in
# main() so comparisons hold on macOS, where /var -> /private/var.
BUNDLED_SKILLS_DIR="$DIR/ai/skills"
CLAUDE_SKILLS_CANON=""
CODEX_HOME_SKILLS_CANON=""
BUNDLED_SKILLS_CANON=""
EXTERNAL_SKILLS_CANON=""

canon() {
    portable_realpath "$1" 2>/dev/null || printf '%s' "$1"
}

# Canonical directory behind a skill entry (real dir or symlink). Fails for a
# dangling link or a non-directory.
resolve_skill_dir() {
    local target
    [ -e "$1" ] || return 1
    target="$(portable_realpath "$1" 2>/dev/null)" || return 1
    [ -d "$target" ] || return 1
    printf '%s\n' "$target"
}

under_codex_home_skills() {
    case "$1" in
        "$CODEX_HOME_SKILLS_DIR"/*|"$CODEX_HOME_SKILLS_CANON"/*) return 0 ;;
    esac
    return 1
}

# Targets this script can produce: bundled repo skills, the upstream clone
# cache, real dirs inside ~/.claude/skills, and Codex's own ~/.codex/skills.
under_managed_root() {
    under_codex_home_skills "$1" && return 0
    case "$1" in
        "$CLAUDE_SKILLS_DIR"/*|"$CLAUDE_SKILLS_CANON"/*|\
        "$BUNDLED_SKILLS_DIR"/*|"$BUNDLED_SKILLS_CANON"/*|\
        "$EXTERNAL_SKILLS_CACHE"/*|"$EXTERNAL_SKILLS_CANON"/*) return 0 ;;
    esac
    return 1
}

# Create $dst -> $src unless $dst already exists. A real dir or a link to
# somewhere else is a printed skip; a link to the same canonical target is a
# silent no-op. Uses ln -s rather than backup_and_link: the contract here is
# "never clobber", and backup_and_link would create a spurious .bak on macOS
# when the logical and canonical paths differ.
link_into() {
    local src="$1" dst="$2" current
    if [ -L "$dst" ]; then
        current="$(portable_realpath "$dst" 2>/dev/null || true)"
        [ "$current" = "$src" ] && return 0
        echo "  Skipping $(display_path "$dst") — already a symlink to ${current:-a missing path}"
        return 0
    fi
    if [ -e "$dst" ]; then
        echo "  Skipping $(display_path "$dst") — exists and is not a symlink"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        echo "[dry-run] Would symlink $src -> $dst"
        return 0
    fi
    # Lazy: ~/.agents/skills appears only on the first real link.
    mkdir -p "$(dirname "$dst")" || return 1
    ln -s "$src" "$dst" || return 1
    echo "  $(display_path "$src") -> $(display_path "$dst")"
}

# A. Claude -> Codex.
sync_claude_to_codex() {
    [ -d "$CLAUDE_SKILLS_DIR" ] || return 0
    local entry name target
    for entry in "$CLAUDE_SKILLS_DIR"/*; do
        [ -e "$entry" ] || continue                    # empty glob or dangling link
        name="$(basename "$entry")"
        [ "$name" = synced ] && continue               # claude.ai synced-skills folder
        [ -f "$entry/SKILL.md" ] || continue
        target="$(resolve_skill_dir "$entry")" || continue
        # Direction-B links resolve into ~/.codex/skills, which Codex already
        # loads natively; mirroring them would load each skill twice.
        under_codex_home_skills "$target" && continue
        # A same-name Codex-native skill wins on the Codex side.
        if [ -d "$CODEX_HOME_SKILLS_DIR/$name" ]; then
            echo "  Skipping $name — Codex already has $(display_path "$CODEX_HOME_SKILLS_DIR/$name")"
            continue
        fi
        run_step "agents/skills:$name" link_into "$target" "$CODEX_AGENT_SKILLS_DIR/$name"
    done
}

# B. Codex -> Claude. Real directories only (skill-installer writes plain
# dirs); dot-dirs such as .system are Codex-internal.
sync_codex_to_claude() {
    [ -d "$CODEX_HOME_SKILLS_DIR" ] || return 0
    local entry name
    for entry in "$CODEX_HOME_SKILLS_DIR"/*; do
        if [ ! -d "$entry" ] || [ -L "$entry" ]; then
            continue
        fi
        name="$(basename "$entry")"
        case "$name" in .*) continue ;; esac
        [ -f "$entry/SKILL.md" ] || continue
        run_step "claude/skills:$name" link_into "$(canon "$entry")" "$CLAUDE_SKILLS_DIR/$name"
    done
}

# Remove dangling links in $1 whose literal target satisfies predicate $2.
# Broken links pointing anywhere else are not ours and survive.
prune_broken_in() {
    local root="$1" predicate="$2" link target
    [ -d "$root" ] || return 0
    for link in "$root"/*; do
        [ -L "$link" ] || continue
        [ -e "$link" ] && continue                     # healthy
        target="$(readlink "$link" 2>/dev/null || true)"
        "$predicate" "$target" || continue
        if [ "$DRY_RUN" = true ]; then
            echo "[dry-run] Would remove broken link $(display_path "$link") -> $target"
        else
            rm -f "$link" && echo "  Removed broken link $(display_path "$link")"
        fi
    done
}

prune_broken() {
    # Direction-A leftovers: anything we could have linked into ~/.agents/skills.
    prune_broken_in "$CODEX_AGENT_SKILLS_DIR" under_managed_root
    # Direction-B leftovers only. Broken links into the upstream clone cache
    # belong to install_claude_skills.sh::prune_orphans.
    prune_broken_in "$CLAUDE_SKILLS_DIR" under_codex_home_skills
}

main() {
    CLAUDE_SKILLS_CANON="$(canon "$CLAUDE_SKILLS_DIR")"
    CODEX_HOME_SKILLS_CANON="$(canon "$CODEX_HOME_SKILLS_DIR")"
    BUNDLED_SKILLS_CANON="$(canon "$BUNDLED_SKILLS_DIR")"
    EXTERNAL_SKILLS_CANON="$(canon "$EXTERNAL_SKILLS_CACHE")"

    echo "Syncing skills between Claude Code and Codex..."
    echo "  Claude: $(display_path "$CLAUDE_SKILLS_DIR")"
    echo "  Codex:  $(display_path "$CODEX_AGENT_SKILLS_DIR") (native: $(display_path "$CODEX_HOME_SKILLS_DIR"))"
    if ! command -v codex &>/dev/null; then
        echo "  codex not installed — links are still created; Codex reads them once installed"
    fi
    echo ""

    prune_broken
    sync_claude_to_codex
    sync_codex_to_claude

    echo ""
    if [ ${#FAILURES[@]} -gt 0 ]; then
        echo "Done with ${#FAILURES[@]} warning(s):"
        for f in "${FAILURES[@]}"; do
            echo "  - $f (non-critical)"
        done
        exit 0
    fi
    echo "Done — agent skills in sync."
}

main "$@"
