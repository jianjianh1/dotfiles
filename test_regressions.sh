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

test_portable_helpers() (
    local tmp file decoded decode_cmd
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    file="$tmp/file.txt"
    printf 'alpha\nremove-me\nbeta\n' > "$file"
    sha256_file "$file" >/dev/null || fail "sha256_file failed"
    decode_cmd="$(base64_decode_cmd)" || fail "base64_decode_cmd did not find a decoder"
    case "$decode_cmd" in
        "base64 -d") decoded="$(printf 'ok' | base64 | base64 -d)" ;;
        "base64 -D") decoded="$(printf 'ok' | base64 | base64 -D)" ;;
        *) fail "base64_decode_cmd returned unexpected command: $decode_cmd" ;;
    esac
    [ "$decoded" = "ok" ] || fail "base64_decode_cmd failed"

    delete_matching_lines "$file" '^remove-me$'
    grep -q remove-me "$file" && fail "delete_matching_lines left matching line"

    ln -s "$file" "$tmp/link"
    [ "$(portable_realpath "$tmp/link")" = "$(portable_realpath "$file")" ] ||
        fail "portable_realpath did not resolve symlink"

    [ "$(to_lower 'ALL')" = "all" ] || fail "to_lower failed"
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
    INSTALL_MANIFEST="$HOME/.server-configs-generated/install-manifest.txt"

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

    remove_tracked_path "$HOME/.codex/config.toml"
    [ ! -e "$HOME/.codex/config.toml" ] || fail "tracked config copy was not removed"
)

test_scripts_source_without_side_effects() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME"

    # shellcheck source=setup.sh
    . "$DIR/setup.sh"
    command -v setup_main >/dev/null || fail "setup_main missing after source"
    [ ! -e "$HOME/.server-configs-generated" ] || fail "sourcing setup.sh created generated state"
)

test_deploy_sources_without_prompting() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME"

    # shellcheck source=deploy.sh
    . "$DIR/deploy.sh"
    command -v deploy_main >/dev/null || fail "deploy_main missing after source"
)

test_setup_dry_run_is_non_mutating() (
    local tmp output
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    output="$(HOME="$tmp/home" bash "$DIR/setup.sh" --dry-run 2>&1)" ||
        fail "setup.sh --dry-run failed: $output"
    printf '%s\n' "$output" | grep -q '\[dry-run\]' ||
        fail "setup.sh --dry-run did not report dry-run steps"
    [ ! -e "$tmp/home/.server-configs-generated" ] ||
        fail "setup.sh --dry-run created generated state"
)

test_pre_commit_no_staged_files() (
    git -C "$DIR" diff --cached --quiet || return 0
    "$DIR/.githooks/pre-commit" || fail "pre-commit failed with no staged files"
)

main() {
    test_remote_bash_lc_quote
    test_portable_helpers
    test_backup_helpers_fail_loudly
    test_manifest_controls_uninstall
    test_scripts_source_without_side_effects
    test_deploy_sources_without_prompting
    test_setup_dry_run_is_non_mutating
    test_pre_commit_no_staged_files
    echo "All regression tests passed."
}

main "$@"
