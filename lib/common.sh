# shellcheck shell=bash
# Shared helpers for setup.sh, deploy.sh, install_claude_plugins.sh.
# Sourced, not executed. Callers must:
#   - run under bash (these use arrays and [[ ]])
#   - define FAILURES=() before sourcing if they want run_step tracking
#   - optionally set AUTO_YES=true to silence run_step's on-failure prompt
#
# Guard so repeated `source` inside one process is cheap.
if [ "${_SERVER_CONFIGS_COMMON_SH:-}" = 1 ]; then
    return 0
fi
_SERVER_CONFIGS_COMMON_SH=1

# Record a failure against $FAILURES if the command fails. If $AUTO_YES is
# unset/false AND stdin is a tty, prompt the caller to continue; otherwise
# fall through silently so non-interactive runs don't hang.
run_step() {
    local name="$1"; shift
    if ! "$@"; then
        FAILURES+=("$name")
        if [ "${AUTO_YES:-false}" != true ] && [ -t 0 ]; then
            local answer
            read -rp "  Step '$name' failed. Continue? [Y/n]: " answer
            case "${answer:-y}" in
                [Nn]*) exit 1 ;;
            esac
        fi
    fi
}

# Retry a command up to 3 times with a 2-second delay.
retry() {
    local attempts=3 delay=2 n=0
    while ! "$@"; do
        n=$((n + 1))
        if [ "$n" -ge "$attempts" ]; then return 1; fi
        echo "  Retrying ($n/$attempts)..." >&2
        sleep "$delay"
    done
}

# Internal: back up $dst to ${dst}.bak if it exists and isn't already a link
# to $src. Leaves the slot empty on return.
_backup_existing() {
    local src="$1" dst="$2" current_target=""
    if [ -L "$dst" ]; then
        current_target="$(readlink -f "$dst" 2>/dev/null || true)"
        if [ "$current_target" = "$src" ]; then
            rm -f "$dst"
            return 0
        fi
        rm -rf "${dst}.bak" 2>/dev/null || true
        echo "  Backing up $dst -> ${dst}.bak"
        mv -f "$dst" "${dst}.bak"
    elif [ -e "$dst" ]; then
        # For copies, skip the backup if content matches; for links, always back up.
        if [ "${3:-link}" = "copy" ] && cmp -s "$src" "$dst" 2>/dev/null; then
            return 0
        fi
        rm -rf "${dst}.bak" 2>/dev/null || true
        echo "  Backing up $dst -> ${dst}.bak"
        mv -f "$dst" "${dst}.bak"
    fi
}

# Replace $dst with a symlink to $src, backing up any existing real file/dir.
backup_and_link() {
    local src="$1" dst="$2"
    _backup_existing "$src" "$dst" link
    mkdir -p "$(dirname "$dst")"
    ln -sf "$src" "$dst"
    echo "  $src -> $dst"
}

# Replace $dst with a copy of $src, backing up any existing real file.
# No-op when the existing content matches, to keep re-runs quiet.
backup_and_copy() {
    local src="$1" dst="$2"
    if [ -e "$dst" ] && [ ! -L "$dst" ] && cmp -s "$src" "$dst" 2>/dev/null; then
        echo "  $dst already up to date"
        return 0
    fi
    _backup_existing "$src" "$dst" copy
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
    echo "  Copied $src -> $dst"
}
