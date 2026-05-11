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
    if [ "${DRY_RUN:-false}" = true ]; then
        echo "[dry-run] Would run: $name"
        return 0
    fi
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

# Retry a command up to 3 times with exponential backoff (2, 4, 8s).
retry() {
    local attempts=3 delay=2 n=0
    while ! "$@"; do
        n=$((n + 1))
        if [ "$n" -ge "$attempts" ]; then return 1; fi
        echo "  Retrying ($n/$attempts) in ${delay}s..." >&2
        sleep "$delay"
        delay=$((delay * 2))
    done
}

os_name() {
    uname -s 2>/dev/null || printf unknown
}

is_macos() {
    [ "$(os_name)" = "Darwin" ]
}

is_linux() {
    [ "$(os_name)" = "Linux" ]
}

is_chpc() {
    # Hostname is the most reliable signal — login/compute nodes always
    # present *.chpc.utah.edu.
    case "${HOSTNAME:-$(hostname 2>/dev/null)}" in
        *.chpc.utah.edu) return 0 ;;
    esac
    # Explicit override for ambiguous cases (sshfs/NFS mounts of CHPC home
    # on a personal machine, container images that ship the path, etc.).
    [ "${CHPC:-}" = 1 ] && return 0
    # Path-only detection turned out too eager: any laptop with /uufs
    # sshfs-mounted from CHPC would trigger CHPC mode. Require both a
    # CHPC-only path AND the `module` command, which are only co-present
    # on actual CHPC systems.
    [ -d "/uufs/chpc.utah.edu/sys" ] && command -v module &>/dev/null && return 0
    return 1
}

machine_arch() {
    local arch
    arch="$(uname -m 2>/dev/null || true)"
    case "$arch" in
        arm64) printf "aarch64" ;;
        *) printf "%s" "$arch" ;;
    esac
}

to_lower() {
    printf "%s" "$1" | tr '[:upper:]' '[:lower:]'
}

portable_realpath() {
    local path="$1" dir base

    if command -v realpath >/dev/null 2>&1; then
        realpath "$path" 2>/dev/null && return 0
    fi

    if [ -L "$path" ]; then
        path="$(readlink "$path" 2>/dev/null || printf "%s" "$path")"
    fi

    dir="$(dirname "$path")"
    base="$(basename "$path")"
    if dir="$(cd "$dir" 2>/dev/null && pwd -P)"; then
        printf "%s/%s\n" "$dir" "$base"
        return 0
    fi

    return 1
}

sha256_file() {
    local path="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        return 1
    fi
}

base64_decode_cmd() {
    if printf "" | base64 -d >/dev/null 2>&1; then
        printf "base64 -d"
    elif printf "" | base64 -D >/dev/null 2>&1; then
        printf "base64 -D"
    else
        return 1
    fi
}

delete_matching_lines() {
    local file="$1" pattern="$2" tmp

    [ -f "$file" ] || return 0
    tmp="$(mktemp "${TMPDIR:-/tmp}/server-configs.XXXXXX")" || return 1
    grep -v -E "$pattern" "$file" > "$tmp" || true
    cat "$tmp" > "$file" || {
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
}

# Quote a command string so it can be passed as the single payload to
# `bash -lc ...` without losing shell metacharacters.
quote_for_bash_lc() {
    local cmd="$1"
    printf '%q' "$cmd"
}

path_is_manifest_managed() {
    # Only paths under $HOME are eligible for manifest tracking. /usr/local/bin
    # was historically allowed too, but that opened a footgun on shared Linux
    # hosts: setup.sh installing into /usr/local/bin (when writable) would
    # record system binaries that uninstall.sh would later sudo-remove.
    local path="$1"
    case "$path" in
        "$HOME"/*) return 0 ;;
        *) return 1 ;;
    esac
}

manifest_contains_path() {
    local path="$1"
    [ -n "${INSTALL_MANIFEST:-}" ] || return 1
    [ -f "$INSTALL_MANIFEST" ] || return 1
    grep -Fqx "$path" "$INSTALL_MANIFEST"
}

manifest_add_path() {
    local path="$1"
    [ -n "${INSTALL_MANIFEST:-}" ] || return 1
    path_is_manifest_managed "$path" || return 0
    mkdir -p "$(dirname "$INSTALL_MANIFEST")" || return 1
    touch "$INSTALL_MANIFEST" || return 1
    manifest_contains_path "$path" || printf '%s\n' "$path" >> "$INSTALL_MANIFEST"
}

# Internal: rotate an existing $dst.bak to a timestamped name unless it is
# byte-identical to $dst (in which case the existing backup already captures
# the same state and can be safely overwritten). Protects against
# destroying a backup the user has edited by hand between setup runs.
_rotate_backup() {
    local dst="$1" bak="${dst}.bak" rotated ts
    [ -e "$bak" ] || return 0
    if [ -f "$bak" ] && [ -f "$dst" ] && cmp -s "$bak" "$dst" 2>/dev/null; then
        rm -f "$bak"
        return 0
    fi
    # Prefer nanosecond granularity (GNU date) so back-to-back rotations
    # within the same second don't all collide and produce `.bak.<ts>~~~`
    # chains. BSD date doesn't support %N; fall back to second granularity.
    ts="$(date +%Y%m%d-%H%M%S.%N 2>/dev/null || true)"
    case "$ts" in
        *N*|"") ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || printf '%s' "$$")" ;;
    esac
    rotated="${bak}.${ts}"
    while [ -e "$rotated" ]; do rotated="${rotated}~"; done
    if mv -f "$bak" "$rotated"; then
        echo "  Preserved edited backup as $rotated"
    fi
}

# Internal: back up $dst to ${dst}.bak if it exists and isn't already a link
# to $src. Leaves the slot empty on return.
_backup_existing() {
    local src="$1" dst="$2" current_target=""
    if [ -L "$dst" ]; then
        current_target="$(portable_realpath "$dst" 2>/dev/null || true)"
        if [ "$current_target" = "$src" ]; then
            rm -f "$dst"
            return 0
        fi
        _rotate_backup "$dst"
        echo "  Backing up $dst -> ${dst}.bak"
        mv -f "$dst" "${dst}.bak"
    elif [ -e "$dst" ]; then
        # For copies, skip the backup if content matches; for links, always back up.
        if [ "${3:-link}" = "copy" ] && cmp -s "$src" "$dst" 2>/dev/null; then
            return 0
        fi
        _rotate_backup "$dst"
        echo "  Backing up $dst -> ${dst}.bak"
        mv -f "$dst" "${dst}.bak"
    fi
}

# Replace $dst with a symlink to $src, backing up any existing real file/dir.
backup_and_link() {
    local src="$1" dst="$2"
    _backup_existing "$src" "$dst" link || return 1
    mkdir -p "$(dirname "$dst")"
    ln -sf "$src" "$dst" || return 1
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
    _backup_existing "$src" "$dst" copy || return 1
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst" || return 1
    echo "  Copied $src -> $dst"
}
