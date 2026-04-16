#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

test_remote_bash_lc_quote() (
    local tmp quoted
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME/.server-configs/.git"

    quoted="$(quote_for_bash_lc '[ -d $HOME/.server-configs/.git ]')"
    eval "bash -lc $quoted" || fail "remote bash -lc quoting lost \$HOME expansion"
)

test_backup_helpers_fail_loudly() (
    local tmp src
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    src="$tmp/src"
    printf 'x\n' > "$src"
    mkdir -p "$tmp/readonly"
    chmod 500 "$tmp/readonly"

    if backup_and_copy "$src" "$tmp/readonly/file" >/dev/null 2>&1; then
        fail "backup_and_copy returned success after a copy failure"
    fi
    if backup_and_link "$src" "$tmp/readonly/link" >/dev/null 2>&1; then
        fail "backup_and_link returned success after a link failure"
    fi
)

test_manifest_controls_uninstall() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME/.server-configs-generated" "$HOME/.local/bin" "$HOME/.codex"

    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/bin/gh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/bin/rg"
    chmod +x "$HOME/.local/bin/gh" "$HOME/.local/bin/rg"
    printf 'config = true\n' > "$HOME/.codex/config.toml"

    # shellcheck source=uninstall.sh
    . "$DIR/uninstall.sh"

    manifest_add_path "$HOME/.local/bin/gh"
    manifest_add_path "$HOME/.codex/config.toml"

    remove_bin gh
    [ ! -e "$HOME/.local/bin/gh" ] || fail "tracked binary was not removed"

    remove_bin rg
    [ -e "$HOME/.local/bin/rg" ] || fail "untracked binary should not be removed"

    remove_tracked_path "$HOME/.codex/config.toml" "~/.codex/config.toml"
    [ ! -e "$HOME/.codex/config.toml" ] || fail "tracked config copy was not removed"
)

main() {
    test_remote_bash_lc_quote
    test_backup_helpers_fail_loudly
    test_manifest_controls_uninstall
    echo "All regression tests passed."
}

main "$@"
