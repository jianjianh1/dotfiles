#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

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
    mkdir -p "$HOME/.dotfiles/.git"

    quoted="$(quote_for_bash_lc '[ -d $HOME/.dotfiles/.git ]')"
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

test_backup_rotation_idempotent_when_identical() (
    # Byte-identical short-circuit branch: existing .bak == dst -> delete
    # in place, no timestamped sibling created.
    local tmp dst
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    dst="$tmp/dst"
    printf 'identical content\n' > "$dst"
    printf 'identical content\n' > "${dst}.bak"

    _rotate_backup "$dst"

    [ -e "${dst}.bak" ] && fail "_rotate_backup left .bak in place when it matched dst"
    local extras
    extras="$(find "$tmp" -maxdepth 1 -name 'dst.bak.*' 2>/dev/null)"
    [ -z "$extras" ] || fail "_rotate_backup created a timestamped backup unnecessarily: $extras"
)

test_remote_capture_strips_banner() (
    local begin='__DEPLOY_CAPTURE_TEST_BEGIN__' end='__DEPLOY_CAPTURE_TEST_END__'
    _extract() {
        awk -v begin="$begin" -v end="$end" '
            $0 == begin { inside = 1; next }
            $0 == end   { found_end = 1; inside = 0; next }
            inside      { print }
            END         { exit (found_end ? 0 : 2) }
        ' <<<"$1"
    }

    local raw extracted rc=0
    raw="$(printf 'Welcome to FakeOS\nLast login: yesterday\n%s\nabc123def\nextra line\n%s\nfooter banner\n' "$begin" "$end")"
    extracted="$(_extract "$raw")" || rc=$?
    [ "$rc" -eq 0 ] || fail "extractor signaled truncation on complete input"
    [ "$extracted" = "abc123def
extra line" ] || fail "extractor returned wrong content: [$extracted]"

    raw="$(printf '%s\nabc\n' "$begin")"
    rc=0
    _extract "$raw" >/dev/null || rc=$?
    [ "$rc" -ne 0 ] || fail "extractor should signal truncation when end marker missing"
)

test_gh_latest_cache_memoizes() (
    local tmp curl_log
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    mkdir -p "$tmp/bin"
    curl_log="$tmp/curl.log"
    cat > "$tmp/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$curl_log"
case "\$*" in
    *-sfL*api.github.com*) printf '{"tag_name":"v9.9.9"}\n' ;;
    *-sfI*github.com*)     printf 'HTTP/2 302\r\nlocation: https://github.com/x/y/releases/tag/v9.9.9\r\n' ;;
esac
EOF
    chmod +x "$tmp/bin/curl"

    # Scope the cache file to $tmp so it gets cleaned up with the test;
    # without this override gh_latest leaks /tmp/.gh-latest-cache.<pid>.
    PATH="$tmp/bin:$PATH" _GH_LATEST_CACHE_FILE="$tmp/gh-cache" bash -c "
        . '$DIR/install.sh'
        v1=\"\$(gh_latest fake/repo)\"
        v2=\"\$(gh_latest fake/repo)\"
        [ \"\$v1\" = '9.9.9' ] || { echo \"v1=\$v1\" >&2; exit 1; }
        [ \"\$v2\" = '9.9.9' ] || { echo \"v2=\$v2\" >&2; exit 1; }
    " || fail "gh_latest did not return the expected version"

    local invocations
    # BSD wc on macOS right-pads its line count with spaces even when
    # reading from stdin -- strip them so the equality check works on
    # both runners.
    invocations="$(wc -l < "$curl_log" 2>/dev/null | tr -d '[:space:]' || echo 0)"
    [ "$invocations" = 1 ] ||
        fail "gh_latest cache miss: expected 1 curl invocation, got $invocations"
)

test_cached_init_handles_empty_output() (
    local tmp run_log
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    mkdir -p "$tmp/bin"
    run_log="$tmp/run.log"
    cat > "$tmp/bin/silentool" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$run_log"
exit 0
EOF
    chmod +x "$tmp/bin/silentool"
    # Age the fake binary so the cache file is unambiguously newer
    # under second-precision `[ -nt ]` (macOS /bin/bash is bash 3.2,
    # which doesn't compare sub-second mtimes). Without this the
    # freshness check fails and the function rewrites the cache every
    # call, breaking the memoization assertion.
    touch -t 197001020000 "$tmp/bin/silentool"

    # Extract just the function definition to a real file: sourcing via
    # `<(sed ...)` is flaky on macOS's bash 3.2 (the FIFO interacts badly
    # with `source`'s seek attempts), so use a temp file instead.
    sed -n '/^_dotfiles_load_cached_init() {$/,/^}$/p' "$DIR/shell/bashrc_exports" > "$tmp/cached_init.bash"

    HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash -c "
        . '$tmp/cached_init.bash'
        _dotfiles_load_cached_init silentool 'silentool init bash'
        _dotfiles_load_cached_init silentool 'silentool init bash'
        _dotfiles_load_cached_init silentool 'silentool init bash'
    " || fail "cached init helper returned non-zero"

    local invocations
    invocations="$(wc -l < "$run_log" 2>/dev/null | tr -d '[:space:]' || echo 0)"
    [ "$invocations" = 1 ] ||
        fail "cached init re-ran on empty output: expected 1 invocation, got $invocations"
)

test_cached_init_evals_output_when_cache_unwritable() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    mkdir -p "$tmp/bin" "$tmp/home/.cache"
    printf 'blocks mkdir -p\n' > "$tmp/home/.cache/dotfiles"
    cat > "$tmp/bin/initool" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "init bash" ] || exit 2
printf '%s\n' 'export INITOOL_READY=1'
EOF
    chmod +x "$tmp/bin/initool"
    touch -t 197001020000 "$tmp/bin/initool"

    sed -n '/^_dotfiles_load_cached_init() {$/,/^}$/p' "$DIR/shell/bashrc_exports" > "$tmp/cached_init.bash"

    HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash -c "
        . '$tmp/cached_init.bash'
        _dotfiles_load_cached_init initool 'initool init bash'
        [ \"\${INITOOL_READY:-}\" = 1 ]
    " || fail "cached init fallback did not eval generated init output"
)

test_backup_rotation_preserves_edited_bak() (
    local tmp src dst rotated
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    src="$tmp/src"
    dst="$tmp/dst"
    printf 'src v1\n' > "$src"
    printf 'original user file\n' > "$dst"

    # Run 1: dst gets backed up to dst.bak (contents: "original user file"),
    # then dst is overwritten by src.
    backup_and_copy "$src" "$dst" >/dev/null 2>&1 || fail "first backup_and_copy failed"
    grep -q '^original user file$' "${dst}.bak" ||
        fail ".bak should contain pre-existing dst content after first run"

    # User edits the .bak (cribbing a snippet from the previous config).
    printf 'user-edited backup\n' > "${dst}.bak"

    # Run 2: src is bumped, so dst is rewritten. The user-edited .bak must
    # be rotated to .bak.<timestamp>, never silently destroyed.
    printf 'src v2\n' > "$src"
    backup_and_copy "$src" "$dst" >/dev/null 2>&1 || fail "second backup_and_copy failed"

    rotated="$(find "$tmp" -maxdepth 1 -name 'dst.bak.*' | head -1)"
    [ -n "$rotated" ] || fail "edited .bak was not rotated to a timestamped name"
    grep -q '^user-edited backup$' "$rotated" ||
        fail "rotated backup did not preserve user-edited content"

    # And the new .bak should hold the previous (run-1) dst content (src v1).
    grep -q '^src v1$' "${dst}.bak" ||
        fail ".bak after run 2 should contain run-1 dst content"
)

test_manifest_controls_uninstall() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME/.dotfiles-generated" "$HOME/.local/bin" "$HOME/.local/opt/nvim/bin" "$HOME/.codex"
    INSTALL_MANIFEST="$HOME/.dotfiles-generated/install-manifest.txt"

    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/bin/gh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/bin/rg"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/bin/detect-theme"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/opt/nvim/bin/nvim"
    ln -s "$HOME/.local/opt/nvim/bin/nvim" "$HOME/.local/bin/nvim"
    : > "$HOME/.dotfiles-generated/tmux-theme.conf"
    ln -s "$HOME/.dotfiles-generated/tmux-theme.conf" "$HOME/.tmux-theme.conf"
    chmod +x "$HOME/.local/bin/gh" "$HOME/.local/bin/rg" "$HOME/.local/bin/detect-theme" "$HOME/.local/opt/nvim/bin/nvim"
    printf 'config = true\n' > "$HOME/.codex/config.toml"

    # shellcheck source=uninstall.sh
    . "$DIR/uninstall.sh"

    manifest_add_path "$HOME/.local/bin/gh"
    manifest_add_path "$HOME/.local/bin/detect-theme"
    manifest_add_path "$HOME/.codex/config.toml"

    remove_bin gh
    [ ! -e "$HOME/.local/bin/gh" ] || fail "tracked binary was not removed"

    remove_bin rg
    [ -e "$HOME/.local/bin/rg" ] || fail "untracked binary should not be removed"

    remove_tools
    [ ! -e "$HOME/.local/bin/detect-theme" ] || fail "tracked detect-theme was not removed by remove_tools"

    remove_symlinks >/dev/null
    [ ! -e "$HOME/.tmux-theme.conf" ] || fail "tmux-theme symlink was not removed"

    remove_tracked_path "$HOME/.codex/config.toml"
    [ ! -e "$HOME/.codex/config.toml" ] || fail "tracked config copy was not removed"

    manifest_add_path "$HOME/.local/bin/nvim"
    manifest_add_path "$HOME/.local/opt/nvim"
    remove_nvim
    [ ! -e "$HOME/.local/bin/nvim" ] || fail "tracked nvim symlink was not removed"
    [ ! -e "$HOME/.local/opt/nvim" ] || fail "tracked nvim opt dir was not removed"
)

test_scripts_source_without_side_effects() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    command -v setup_main >/dev/null || fail "setup_main missing after source"
    [ ! -e "$HOME/.dotfiles-generated" ] || fail "sourcing install.sh created generated state"
)

test_detect_theme_installs_to_local_bin() (
    local tmp target
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME/.dotfiles-generated"
    INSTALL_MANIFEST="$HOME/.dotfiles-generated/install-manifest.txt"
    BIN_DIR="$tmp/not-used"
    # shellcheck disable=SC2034 # consumed by sourced install.sh helpers
    DRY_RUN=false

    # shellcheck source=install.sh
    . "$DIR/install.sh"

    install_detect_theme >/dev/null || fail "install_detect_theme failed"
    [ -L "$HOME/.local/bin/detect-theme" ] || fail "detect-theme was not linked into ~/.local/bin"
    target="$(portable_realpath "$HOME/.local/bin/detect-theme" 2>/dev/null || true)"
    [ "$target" = "$DIR/scripts/detect-theme.sh" ] || fail "detect-theme symlink points at '$target'"
    manifest_contains_path "$HOME/.local/bin/detect-theme" ||
        fail "detect-theme local-bin path was not recorded in manifest"
    [ ! -e "$BIN_DIR/detect-theme" ] || fail "detect-theme should ignore BIN_DIR"
)

test_codex_mcp_bridge_installs_to_local_bin() (
    local tmp target
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME/.dotfiles-generated"
    INSTALL_MANIFEST="$HOME/.dotfiles-generated/install-manifest.txt"
    DRY_RUN=false

    # shellcheck source=install.sh
    . "$DIR/install.sh"

    install_codex_mcp_bridge >/dev/null || fail "install_codex_mcp_bridge failed"
    [ -x "$HOME/.local/bin/codex-mcp-bridge" ] ||
        fail "Codex MCP bridge was not linked into ~/.local/bin"
    target="$(portable_realpath "$HOME/.local/bin/codex-mcp-bridge" 2>/dev/null || true)"
    [ "$target" = "$DIR/scripts/codex-mcp-bridge.mjs" ] ||
        fail "Codex MCP bridge symlink points at '$target'"
    manifest_contains_path "$HOME/.local/bin/codex-mcp-bridge" ||
        fail "Codex MCP bridge was not recorded in the manifest"
)

test_tmux_clipboard_compat_uses_global_scope() (
    local tmp compat
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    mkdir -p "$GENERATED_DIR"
    tmux_default_terminal() { printf 'screen-256color\n'; }
    tmux_version() { printf '%s\n' "${TMUX_TEST_VERSION:-3.2}"; }

    TMUX_TEST_VERSION=3.2
    render_tmux_compat
    compat="$GENERATED_DIR/tmux.compat.conf"
    grep -qx 'set -g set-clipboard on' "$compat" ||
        fail "tmux compat config did not use global set-clipboard scope"
    if grep -q 'set -s set-clipboard' "$compat"; then
        fail "tmux compat config retained the server-scoped clipboard command"
    fi

    TMUX_TEST_VERSION=2.5
    render_tmux_compat
    if grep -q '^set .*set-clipboard' "$compat"; then
        fail "tmux < 2.6 received an unsupported set-clipboard command"
    fi
    grep -q 'clipboard integration unavailable' "$compat" ||
        fail "tmux < 2.6 fallback comment is missing"
)

test_claude_statusline() (
    local tmp repo fixture wide narrow fallback
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    repo="$tmp/repo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name Test
    printf 'tracked\n' > "$repo/tracked.txt"
    git -C "$repo" add tracked.txt
    git -C "$repo" commit -qm initial
    printf 'dirty\n' >> "$repo/tracked.txt"

    fixture="$(printf '%s' '{"model":{"display_name":"Opus 4.1"},"effort_level":"high","session_name":"fixture-session","workspace":{"current_dir":"REPO"},"pull_request":{"number":17},"context_window":{"used_percentage":42,"current_usage":{"cache_read_input_tokens":800,"input_tokens":200}},"rate_limits":{"five_hour":{"used_percentage":25},"seven_day":{"used_percentage":40}},"cost":{"total_cost_usd":1.234,"total_duration_ms":125000,"total_lines_added":10,"total_lines_removed":3}}' | sed "s|REPO|$repo|")"

    wide="$(printf '%s' "$fixture" | NO_COLOR=1 TERM=dumb COLUMNS=160 "$DIR/ai/claude_statusline.sh")" ||
        fail "Claude status line failed on a valid fixture"
    [ "$(printf '%s\n' "$wide" | wc -l | tr -d ' ')" -eq 2 ] ||
        fail "Claude status line should render exactly two lines"
    printf '%s\n' "$wide" | grep -q 'Opus 4.1.*effort high.*fixture-session' ||
        fail "Claude status line omitted model, effort, or session"
    printf '%s\n' "$wide" | grep -q 'git:.*\*.*PR #17' ||
        fail "Claude status line omitted dirty git or PR state"
    printf '%s\n' "$wide" | grep -q 'ctx .*42%.*5h 75% left.*7d 60% left' ||
        fail "Claude status line omitted context or rate limits"
    printf '%s\n' "$wide" | grep -q 'cache 80%.*\$1.23.*2m05s.*+10/-3' ||
        fail "Claude status line omitted cache, cost, duration, or diff details"
    if printf '%s' "$wide" | grep -q $'\033'; then
        fail "Claude status line ignored NO_COLOR"
    fi

    narrow="$(printf '%s' "$fixture" | NO_COLOR=1 TERM=dumb COLUMNS=90 "$DIR/ai/claude_statusline.sh")"
    if printf '%s\n' "$narrow" | grep -Eq 'fixture-session|PR #17|cache 80%|\$1.23'; then
        fail "Claude status line did not trim low-priority fields in a narrow terminal"
    fi
    printf '%s\n' "$narrow" | grep -q 'Opus 4.1.*git:' ||
        fail "Claude status line trimmed essential narrow-terminal fields"

    fallback="$(printf 'not-json' | "$DIR/ai/claude_statusline.sh")"
    [ "$fallback" = Claude ] || fail "Claude status line invalid-input fallback changed"
)

test_codex_mcp_bridge_protocol() (
    local tmp fake_codex output log
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    fake_codex="$tmp/codex"
    log="$tmp/codex.log"
    mkdir -p "$tmp/work"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s\n" "$*" >> "$CODEX_TEST_LOG"' \
        'case " $* " in' \
        '  *" force-error "*) printf "simulated failure\n" >&2; exit 7 ;;' \
        '  *" resume "*)' \
        '    printf '\''{"type":"thread.started","thread_id":"thread-resumed"}\n'\''' \
        '    printf '\''{"type":"item.completed","item":{"type":"agent_message","text":"resumed answer"}}\n'\''' \
        '    ;;' \
        '  *)' \
        '    printf '\''{"type":"thread.started","thread_id":"thread-new"}\n'\''' \
        '    printf '\''{"type":"item.completed","item":{"type":"agent_message","text":"new answer"}}\n'\''' \
        '    ;;' \
        'esac' > "$fake_codex"
    chmod +x "$fake_codex"

    output="$(printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}' \
        '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"codex\",\"arguments\":{\"prompt\":\"review\",\"cwd\":\"$tmp/work\",\"sandbox\":\"read-only\",\"approval-policy\":\"never\",\"model\":\"gpt-test\"}}}" \
        '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"codex-reply","arguments":{"threadId":"thread-new","prompt":"continue"}}}' \
        '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"codex","arguments":{"prompt":"unsafe","sandbox":"danger-full-access"}}}' \
        '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"codex","arguments":{"prompt":"force-error"}}}' |
        CODEX_BIN="$fake_codex" CODEX_TEST_LOG="$log" node "$DIR/scripts/codex-mcp-bridge.mjs")" ||
        fail "Codex MCP bridge protocol run failed"

    printf '%s\n' "$output" | jq -s -e '
        (map(select(.id == 1))[0].result.serverInfo.name == "dotfiles-codex-bridge") and
        (map(select(.id == 2))[0].result.tools | map(.name) | sort == ["codex", "codex-reply"]) and
        (map(select(.id == 3))[0].result.structuredContent == {threadId:"thread-new", content:"new answer"}) and
        (map(select(.id == 4))[0].result.structuredContent.content == "resumed answer") and
        (map(select(.id == 5))[0].result.isError == true) and
        (map(select(.id == 6))[0].result.isError == true)
    ' >/dev/null || fail "Codex MCP bridge returned incorrect protocol responses"
    if printf '%s\n' "$output" | jq -e '.result.tools[]?.inputSchema.properties.sandbox.enum[]? | select(. == "danger-full-access")' >/dev/null; then
        fail "Codex MCP bridge exposed danger-full-access delegation"
    fi
    grep -q -- '-a never exec --json --color never --skip-git-repo-check -s read-only' "$log" ||
        fail "Codex MCP bridge did not force headless read-only defaults"
    grep -q -- "-C $tmp/work -m gpt-test review" "$log" ||
        fail "Codex MCP bridge did not forward cwd, model, and prompt"
    grep -q -- '-a never exec resume --json --skip-git-repo-check thread-new continue' "$log" ||
        fail "Codex MCP bridge did not invoke codex exec resume"
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

test_remote_dotfiles_preflight_snippet() (
    local tmp snippet
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME"

    # shellcheck source=deploy.sh
    . "$DIR/deploy.sh"
    snippet="$(remote_dotfiles_preflight_snippet)"

    mkdir -p "$HOME/.dotfiles"
    DOTFILES_REMOTE_DIR="$HOME/.dotfiles" bash -c "$snippet" >/dev/null ||
        fail "preflight rejected an empty non-git dotfiles directory"
    [ ! -e "$HOME/.dotfiles" ] ||
        fail "preflight did not remove an empty non-git dotfiles directory"

    mkdir -p "$HOME/.dotfiles"
    printf 'keep\n' > "$HOME/.dotfiles/file"
    if DOTFILES_REMOTE_DIR="$HOME/.dotfiles" bash -c "$snippet" >/dev/null 2>&1; then
        fail "preflight accepted a non-empty non-git dotfiles directory"
    fi
    [ -f "$HOME/.dotfiles/file" ] ||
        fail "preflight removed user content from a non-empty dotfiles directory"
)

test_git_clone_command_uses_gh_only_for_credentials() (
    local tmp good_git cmd fallback_cmd
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME" "$tmp/bin"
    good_git="$tmp/bin/git"
    printf '#!/bin/sh\nexit 0\n' > "$good_git"
    chmod +x "$good_git"

    # shellcheck source=deploy.sh
    . "$DIR/deploy.sh"

    cmd="$(remote_git_clone_cmd 'unset GIT_EXEC_PATH GIT_TEMPLATE_DIR;' "$tmp/bin" "$good_git" "https://github.com/jianjianh1/dotfiles.git" '$HOME/.dotfiles' true)"
    printf '%s\n' "$cmd" | grep -Fq "'$good_git'" ||
        fail "gh-authenticated clone command did not use the selected git: $cmd"
    printf '%s\n' "$cmd" | grep -Fq "credential.https://github.com.helper='!gh auth git-credential'" ||
        fail "gh-authenticated clone command did not use gh credential helper: $cmd"
    printf '%s\n' "$cmd" | grep -Fq "clone https://github.com/jianjianh1/dotfiles.git" ||
        fail "gh-authenticated clone command did not clone the repo URL: $cmd"
    printf '%s\n' "$cmd" | grep -Fq '$HOME/.dotfiles' ||
        fail "gh-authenticated clone command did not target remote dotfiles dir: $cmd"
    if printf '%s\n' "$cmd" | grep -q 'gh repo clone'; then
        fail "gh-authenticated clone command still uses gh repo clone"
    fi

    fallback_cmd="$(remote_git_clone_cmd 'unset GIT_EXEC_PATH GIT_TEMPLATE_DIR;' "$tmp/bin" "$good_git" "https://github.com/jianjianh1/dotfiles.git" '$HOME/.dotfiles' false)"
    printf '%s\n' "$fallback_cmd" | grep -Fq "'$good_git' clone https://github.com/jianjianh1/dotfiles.git" ||
        fail "fallback clone command did not use plain git clone: $fallback_cmd"
    printf '%s\n' "$fallback_cmd" | grep -Fq '$HOME/.dotfiles' ||
        fail "fallback clone command did not target remote dotfiles dir: $fallback_cmd"
)

test_remote_git_probe_snippet() (
    local tmp snippet out good_exec good_git bad_exec bad_git
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME" "$tmp/bin"
    # Keep git-core off PATH so `command -v git-remote-https` only sees what we
    # plant here, making the cases deterministic on any host.
    export PATH="$tmp/bin:/usr/bin:/bin"

    # shellcheck source=deploy.sh
    . "$DIR/deploy.sh"
    snippet="$(remote_git_probe_snippet)"

    # Case 1: a git whose --exec-path holds an executable git-remote-https.
    good_exec="$tmp/good-exec"
    mkdir -p "$good_exec"
    printf '#!/bin/sh\ntrue\n' > "$good_exec/git-remote-https"
    chmod +x "$good_exec/git-remote-https"
    good_git="$tmp/good-git"
    printf '#!/bin/sh\n[ "$1" = "--exec-path" ] && echo "%s"\nexit 0\n' "$good_exec" > "$good_git"
    chmod +x "$good_git"
    out="$(DOTFILES_GIT_CANDIDATES="$good_git" bash -c "$snippet")" ||
        fail "probe rejected a healthy git"
    [ "$out" = "$good_git" ] || fail "probe returned '$out', expected '$good_git'"

    # Case 2: a git whose --exec-path lacks git-remote-https, none on PATH.
    bad_exec="$tmp/bad-exec"
    mkdir -p "$bad_exec"
    bad_git="$tmp/bad-git"
    printf '#!/bin/sh\n[ "$1" = "--exec-path" ] && echo "%s"\nexit 0\n' "$bad_exec" > "$bad_git"
    chmod +x "$bad_git"
    if out="$(DOTFILES_GIT_CANDIDATES="$bad_git" bash -c "$snippet")"; then
        fail "probe accepted a git with no git-remote-https (returned '$out')"
    fi
    [ -z "$out" ] || fail "probe emitted '$out' for an unusable git"

    # Case 3: broken --exec-path but git-remote-https present on PATH.
    printf '#!/bin/sh\ntrue\n' > "$tmp/bin/git-remote-https"
    chmod +x "$tmp/bin/git-remote-https"
    out="$(DOTFILES_GIT_CANDIDATES="$bad_git" bash -c "$snippet")" ||
        fail "probe rejected a git whose helper is on PATH"
    [ "$out" = "$bad_git" ] || fail "probe returned '$out', expected '$bad_git'"
)

test_auth_state_helpers() (
    local tmp state quoted quoted_value
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    export PATH="$tmp/bin:/usr/bin:/bin"
    unset GH_CONFIG_DIR XDG_CONFIG_HOME CLAUDE_CONFIG_DIR CODEX_HOME
    unset ANTHROPIC_API_KEY OPENAI_API_KEY GH_STATUS_EXIT GH_TOKEN_VALUE CLAUDE_STATUS_EXIT
    mkdir -p "$HOME" "$tmp/bin"

    # shellcheck source=deploy.sh
    . "$DIR/deploy.sh"

    quoted="$(shell_quote_env_value "alpha'beta")"
    eval "quoted_value=$quoted"
    [ "$quoted_value" = "alpha'beta" ] ||
        fail "shell_quote_env_value did not preserve apostrophes"

    [ "$(local_gh_config_dir)" = "$HOME/.config/gh" ] ||
        fail "local_gh_config_dir did not default to ~/.config/gh"
    export XDG_CONFIG_HOME="$tmp/xdg"
    [ "$(local_gh_config_dir)" = "$tmp/xdg/gh" ] ||
        fail "local_gh_config_dir did not honor XDG_CONFIG_HOME"
    export GH_CONFIG_DIR="$tmp/gh-config"
    [ "$(local_gh_config_dir)" = "$tmp/gh-config" ] ||
        fail "local_gh_config_dir did not honor GH_CONFIG_DIR"

    state="$(auth_state_gh "$tmp/missing-hosts.yml")"
    [ "$(auth_state_status "$state")" = "missing" ] ||
        fail "auth_state_gh should be missing without gh"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'case "$1 $2" in' \
        '  "auth status") exit "${GH_STATUS_EXIT:-0}" ;;' \
        '  "auth token") [ -n "${GH_TOKEN_VALUE:-}" ] && printf "%s\n" "$GH_TOKEN_VALUE"; exit 0 ;;' \
        '  *) exit 1 ;;' \
        'esac' > "$tmp/bin/gh"
    chmod +x "$tmp/bin/gh"

    export GH_STATUS_EXIT=1
    state="$(auth_state_gh "$tmp/missing-hosts.yml")"
    [ "$(auth_state_status "$state")" = "missing" ] ||
        fail "auth_state_gh should be missing when gh is unauthenticated"

    export GH_STATUS_EXIT=0 GH_TOKEN_VALUE=secret-token
    state="$(auth_state_gh "$tmp/missing-hosts.yml")"
    [ "$(auth_state_status "$state")" = "deployable" ] &&
        printf '%s\n' "$state" | grep -q 'gh auth token' ||
        fail "auth_state_gh should prefer gh auth token"

    unset GH_TOKEN_VALUE
    mkdir -p "$(dirname "$(local_gh_hosts_file)")"
    printf 'github.com:\n    oauth_token: secret-token\n' > "$(local_gh_hosts_file)"
    state="$(auth_state_gh "$(local_gh_hosts_file)")"
    [ "$(auth_state_status "$state")" = "deployable" ] &&
        printf '%s\n' "$state" | grep -q 'hosts.yml' ||
        fail "auth_state_gh should fall back to plaintext hosts.yml token"

    rm -f "$(local_gh_hosts_file)"
    state="$(auth_state_gh "$(local_gh_hosts_file)")"
    [ "$(auth_state_status "$state")" = "blocked" ] ||
        fail "auth_state_gh should be blocked for keychain-only auth with unreadable token"

    export CLAUDE_CONFIG_DIR="$tmp/claude"
    state="$(auth_state_claude)"
    [ "$(auth_state_status "$state")" = "missing" ] ||
        fail "auth_state_claude should be missing without file or CLI login"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'case "$1 $2" in' \
        '  "auth status") exit "${CLAUDE_STATUS_EXIT:-0}" ;;' \
        '  *) exit 1 ;;' \
        'esac' > "$tmp/bin/claude"
    chmod +x "$tmp/bin/claude"

    export CLAUDE_STATUS_EXIT=0
    state="$(auth_state_claude)"
    [ "$(auth_state_status "$state")" = "blocked" ] ||
        fail "auth_state_claude should be blocked for login without credentials file"

    mkdir -p "$CLAUDE_CONFIG_DIR"
    printf '{}\n' > "$CLAUDE_CONFIG_DIR/.credentials.json"
    state="$(auth_state_claude)"
    [ "$(auth_state_status "$state")" = "deployable" ] ||
        fail "auth_state_claude should be deployable when credentials file exists"

    export CODEX_HOME="$tmp/codex"
    state="$(auth_state_codex)"
    [ "$(auth_state_status "$state")" = "missing" ] ||
        fail "auth_state_codex should be missing without auth.json"
    mkdir -p "$CODEX_HOME"
    printf '{}\n' > "$CODEX_HOME/auth.json"
    state="$(auth_state_codex)"
    [ "$(auth_state_status "$state")" = "deployable" ] ||
        fail "auth_state_codex should be deployable with auth.json"

    state="$(auth_state_api_keys)"
    [ "$(auth_state_status "$state")" = "missing" ] ||
        fail "auth_state_api_keys should be missing without env vars"
    export OPENAI_API_KEY=test-key
    state="$(auth_state_api_keys)"
    [ "$(auth_state_status "$state")" = "deployable" ] &&
        printf '%s\n' "$state" | grep -q 'OPENAI_API_KEY' ||
        fail "auth_state_api_keys should list deployable key names"
)

test_rclone_config_helpers() (
    local tmp config section destination state mode before
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    unset RCLONE_CONFIG XDG_CONFIG_HOME
    mkdir -p "$HOME/.config/rclone"
    config="$HOME/.config/rclone/rclone.conf"

    [ "$(rclone_config_file)" = "$config" ] ||
        fail "rclone_config_file did not select the standard config path"
    state="$(rclone_gdrive_auth_state "$config")"
    [ "${state%%|*}" = missing ] || fail "missing rclone config was not reported missing"

    printf '%s\n' \
        '[other]' \
        'type = s3' \
        'access_key_id = keep-me' \
        '' \
        '[gdrive]' \
        'type = drive' \
        'client_id = personal-client.apps.googleusercontent.com' \
        'client_secret = fake-client-secret' \
        'scope = drive' \
        'token = {"access_token":"fake-access-token"}' > "$config"
    chmod 600 "$config"

    state="$(rclone_gdrive_auth_state "$config")"
    [ "${state%%|*}" = deployable ] || fail "valid gdrive config was not deployable: $state"
    case "$state" in
        *fake-client-secret*|*fake-access-token*) fail "auth state exposed rclone secrets" ;;
    esac

    section="$tmp/gdrive.conf"
    rclone_extract_remote_section "$config" gdrive > "$section"
    rclone_gdrive_profile_valid "$section" || fail "extracted gdrive profile was not valid"
    if grep -q '^\[other\]$' "$section"; then
        fail "gdrive extraction included an unrelated remote"
    fi

    destination="$tmp/remote/rclone.conf"
    mkdir -p "$(dirname "$destination")"
    printf '%s\n' \
        '[remote-only]' \
        'type = sftp' \
        'host = preserve.example' \
        '' \
        '[gdrive]' \
        'type = drive' \
        'scope = drive.file' \
        'token = old-token' > "$destination"
    rclone_merge_gdrive_section "$section" "$destination" || fail "gdrive section merge failed"
    grep -q '^\[remote-only\]$' "$destination" || fail "merge removed a remote-only profile"
    grep -q '^host = preserve.example$' "$destination" || fail "merge changed unrelated settings"
    grep -q '^scope = drive$' "$destination" || fail "merge did not install the full-drive profile"
    if grep -q 'old-token' "$destination"; then fail "merge retained the old gdrive token"; fi
    [ "$(grep -c '^\[gdrive\]$' "$destination")" -eq 1 ] || fail "merge created duplicate gdrive sections"
    mode="$(stat -c '%a' "$destination" 2>/dev/null || stat -f '%Lp' "$destination")"
    [ "$mode" = 600 ] || fail "merged rclone config mode is $mode, expected 600"

    before="$(sha256_file "$destination")"
    printf 'RCLONE_ENCRYPT_V0:\nnot-a-real-encrypted-config\n' > "$destination"
    if rclone_merge_gdrive_section "$section" "$destination" >/dev/null 2>&1; then
        fail "merge accepted an encrypted destination"
    fi
    grep -q '^RCLONE_ENCRYPT_V0:' "$destination" || fail "failed merge changed encrypted destination"

    printf '%s\n' \
        '[gdrive]' \
        'type = drive' \
        'scope = drive.file' \
        'token = restricted-token' > "$config"
    state="$(rclone_gdrive_auth_state "$config")"
    [ "${state%%|*}" = blocked ] || fail "restricted/shared-client config was not blocked"
    [ -n "$before" ] || fail "sha256 helper returned an empty digest"
)

test_rclone_deploy_merges_only_gdrive() (
    local tmp local_home remote_home config destination first_sum
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    local_home="$tmp/local-home"
    remote_home="$tmp/remote-home"
    mkdir -p "$local_home/.config/rclone" "$remote_home/.config/rclone"
    export HOME="$local_home"
    config="$HOME/.config/rclone/rclone.conf"
    printf '%s\n' \
        '[local-only]' \
        'type = dropbox' \
        'token = do-not-copy' \
        '' \
        '[gdrive]' \
        'type = drive' \
        'client_id = personal-client.apps.googleusercontent.com' \
        'client_secret = fake-client-secret' \
        'scope = drive' \
        'token = {"access_token":"fake-access-token"}' > "$config"
    chmod 600 "$config"
    destination="$remote_home/.config/rclone/rclone.conf"
    printf '%s\n' \
        '[remote-only]' \
        'type = sftp' \
        'host = preserve.example' > "$destination"

    # shellcheck source=deploy.sh
    . "$DIR/deploy.sh"
    remote_exec() { HOME="$remote_home" bash -c "$1"; }
    remote_capture() { HOME="$remote_home" bash -c "$1"; }
    copy_local_file_to_remote() {
        local source="$1" remote_path="$2" mode="${3:-600}" resolved
        resolved="$(printf '%s' "$remote_path" | sed "s|^\\\$HOME|$remote_home|")"
        mkdir -p "$(dirname "$resolved")" || return 1
        cp "$source" "$resolved" || return 1
        chmod "$mode" "$resolved"
    }

    FORCE_COPY=0
    copy_gdrive_auth_to_remote "$config" >/dev/null || fail "gdrive deploy helper failed"
    grep -q '^\[remote-only\]$' "$destination" || fail "deploy removed a remote-only profile"
    grep -q '^\[gdrive\]$' "$destination" || fail "deploy did not add gdrive"
    if grep -q '^\[local-only\]$' "$destination"; then fail "deploy copied an unrelated local profile"; fi
    first_sum="$(sha256_file "$destination")"
    copy_gdrive_auth_to_remote "$config" >/dev/null || fail "idempotent gdrive deploy failed"
    [ "$first_sum" = "$(sha256_file "$destination")" ] || fail "idempotent deploy rewrote the config"
)

test_rclone_install_uses_managed_local_bin() (
    local tmp curl_log
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME/.dotfiles-generated" "$tmp/bin"
    INSTALL_MANIFEST="$HOME/.dotfiles-generated/install-manifest.txt"
    : > "$INSTALL_MANIFEST"
    curl_log="$tmp/curl.log"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'out=""; url=""' \
        'while [ $# -gt 0 ]; do' \
        '  case "$1" in -o) out="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac' \
        'done' \
        'printf "%s\n" "$url" >> "$RCLONE_TEST_CURL_LOG"' \
        'printf "fake zip\n" > "$out"' > "$tmp/bin/curl"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'dest=""' \
        'while [ $# -gt 0 ]; do' \
        '  case "$1" in -d) dest="$2"; shift 2 ;; *) shift ;; esac' \
        'done' \
        'mkdir -p "$dest/rclone-test"' \
        'printf "#!/usr/bin/env bash\\nprintf '\''rclone v9.9.9\\n'\''\\n" > "$dest/rclone-test/rclone"' \
        'chmod +x "$dest/rclone-test/rclone"' > "$tmp/bin/unzip"
    chmod +x "$tmp/bin/curl" "$tmp/bin/unzip"

    export PATH="$tmp/bin:/usr/bin:/bin"
    export RCLONE_TEST_CURL_LOG="$curl_log"
    FORCE=false
    NO_UPDATE=false
    DRY_RUN=false
    TEST_RCLONE_ARCH=x86_64

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    rclone_latest() { printf '9.9.9\n'; }
    machine_arch() { printf '%s\n' "$TEST_RCLONE_ARCH"; }
    report_rclone_gdrive_config() { :; }

    install_rclone >/dev/null || fail "managed rclone install failed"
    [ -x "$HOME/.local/bin/rclone" ] || fail "rclone was not installed into ~/.local/bin"
    manifest_contains_path "$HOME/.local/bin/rclone" || fail "rclone was not recorded in the manifest"
    grep -q 'rclone-v9.9.9-linux-amd64.zip' "$curl_log" || fail "rclone selected the wrong amd64 asset"

    TEST_RCLONE_ARCH=aarch64
    FORCE=true
    install_rclone >/dev/null || fail "forced arm64 rclone install failed"
    tail -1 "$curl_log" | grep -q 'rclone-v9.9.9-linux-arm64.zip' ||
        fail "rclone selected the wrong arm64 asset"
)

test_setup_dry_run_is_non_mutating() (
    local tmp output
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    output="$(HOME="$tmp/home" bash "$DIR/install.sh" --dry-run 2>&1)" ||
        fail "install.sh --dry-run failed: $output"
    printf '%s\n' "$output" | grep -q '\[dry-run\]' ||
        fail "install.sh --dry-run did not report dry-run steps"
    [ ! -e "$tmp/home/.dotfiles-generated" ] ||
        fail "install.sh --dry-run created generated state"
)

test_chpc_config_rendering_uses_repo_files() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    export HOSTNAME="login1.chpc.utah.edu"
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
    mkdir -p "$HOME"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    mkdir -p "$GENERATED_DIR"
    render_compat_configs

    [ "$CLAUDE_SETTINGS_MODE" = "repo" ] ||
        fail "CHPC Claude settings should use the repo file directly (got mode '$CLAUDE_SETTINGS_MODE')"
    [ "$CLAUDE_SETTINGS_SRC" = "$DIR/ai/claude_settings.json" ] ||
        fail "CHPC Claude settings src should be the repo file (got '$CLAUDE_SETTINGS_SRC')"
    [ "$CODEX_CONFIG_MODE" = "repo" ] ||
        fail "CHPC Codex config should use the repo file directly (got mode '$CODEX_CONFIG_MODE')"
    [ "$CODEX_CONFIG_SRC" = "$DIR/ai/codex_config.toml" ] ||
        fail "CHPC Codex config src should be the repo file (got '$CODEX_CONFIG_SRC')"

    grep -q '"defaultMode": "bypassPermissions"' "$DIR/ai/claude_settings.json" ||
        fail "Repo Claude settings should use bypassPermissions per no-restriction defaults"
    grep -q '"enabled": false' "$DIR/ai/claude_settings.json" ||
        fail "Repo Claude settings should disable sandboxing per no-restriction defaults"

    grep -q 'approval_policy = "never"' "$DIR/ai/codex_config.toml" ||
        fail "Repo Codex config should auto-approve per no-restriction defaults"
    grep -q 'sandbox_mode = "danger-full-access"' "$DIR/ai/codex_config.toml" ||
        fail "Repo Codex config should use danger-full-access per no-restriction defaults"
)

test_chpc_module_loads_initialize_module_command() (
    local tmp bash_compat init_line claude_line codex_line
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    export HOSTNAME="login1.chpc.utah.edu"
    mkdir -p "$HOME"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    mkdir -p "$GENERATED_DIR"
    # shellcheck disable=SC2034 # render_bash_compat reads module variables indirectly.
    CLAUDE_MODULE="claude-code"
    # shellcheck disable=SC2034 # render_bash_compat reads module variables indirectly.
    CODEX_MODULE="codex"
    render_bash_compat

    bash_compat="$GENERATED_DIR/bashrc_compat"
    init_line="$(grep -n 'for init in /etc/profile.d/modules.sh' "$bash_compat" | cut -d: -f1)"
    claude_line="$(grep -n '_dotfiles_module_load claude-code' "$bash_compat" | cut -d: -f1)"
    codex_line="$(grep -n '_dotfiles_module_load codex' "$bash_compat" | cut -d: -f1)"

    [ -n "$init_line" ] || fail "module initialization block missing"
    [ -n "$claude_line" ] || fail "Claude module load missing"
    [ -n "$codex_line" ] || fail "Codex module load missing"
    [ "$init_line" -lt "$claude_line" ] ||
        fail "Claude module load should come after module initialization"
    [ "$init_line" -lt "$codex_line" ] ||
        fail "Codex module load should come after module initialization"

    # Module loads must be gated on interactive shells so SLURM job-step
    # shells don't unintentionally swap modules at startup.
    grep -q 'case $- in' "$bash_compat" ||
        fail "module section missing interactive-shell guard"
)

test_module_var_reset_clears_stale_values() (
    local tmp bash_compat
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
    mkdir -p "$HOME"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    mkdir -p "$GENERATED_DIR"

    CLAUDE_MODULE="stale-claude"
    CODEX_MODULE="stale-codex"
    reset_module_vars
    [ -z "${CLAUDE_MODULE:-}" ] || fail "reset_module_vars did not clear CLAUDE_MODULE"
    [ -z "${CODEX_MODULE:-}" ] || fail "reset_module_vars did not clear CODEX_MODULE"

    render_bash_compat
    bash_compat="$GENERATED_DIR/bashrc_compat"
    if grep -Eq '(_dotfiles_module_load|module load) stale-' "$bash_compat"; then
        fail "stale module values leaked into bash compat config"
    fi
)

test_nvim_manifest_records_only_owned_layout() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    mkdir -p "$GENERATED_DIR" "$HOME/.local/bin" "$HOME/.local/opt/nvim/bin"
    : > "$INSTALL_MANIFEST"

    record_nvim_manifest
    if [ -s "$INSTALL_MANIFEST" ]; then
        fail "record_nvim_manifest should not track unowned nvim paths"
    fi

    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/opt/nvim/bin/nvim"
    chmod +x "$HOME/.local/opt/nvim/bin/nvim"
    ln -s "$HOME/.local/opt/nvim/bin/nvim" "$HOME/.local/bin/nvim"

    record_nvim_manifest
    manifest_contains_path "$HOME/.local/bin/nvim" ||
        fail "record_nvim_manifest did not track owned nvim symlink"
    manifest_contains_path "$HOME/.local/opt/nvim" ||
        fail "record_nvim_manifest did not track owned nvim opt dir"
)

test_nvim_install_selects_legacy_and_arm_assets() (
    local tmp calls
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
    mkdir -p "$HOME"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    # shellcheck disable=SC2034 # consumed by install_nvim/install helpers
    FORCE=true
    # shellcheck disable=SC2034 # consumed by install_nvim/install helpers
    CHPC_USE_MODULES=false

    is_macos() { return 1; }
    is_chpc() { return 1; }

    calls="$tmp/old-glibc-calls"
    machine_arch() { printf 'x86_64'; }
    glibc_version() { printf '2.17'; }
    install_nvim_tarball() {
        printf 'tarball %s %s\n' "$1" "$2" >> "$calls"
        case "$2" in
            *neovim-releases*) return 0 ;;
            *) return 1 ;;
        esac
    }
    install_nvim_appimage() {
        printf 'appimage %s %s\n' "$1" "$2" >> "$calls"
        return 1
    }

    install_nvim >/dev/null 2>&1 ||
        fail "old-glibc nvim install should use legacy tarball"
    grep -q 'neovim-releases' "$calls" ||
        fail "old-glibc nvim install did not use legacy release repo"
    if grep -q 'appimage' "$calls"; then
        fail "old-glibc nvim install should skip AppImage"
    fi

    calls="$tmp/arm-calls"
    machine_arch() { printf 'aarch64'; }
    glibc_version() { :; }
    install_nvim_tarball() {
        printf 'tarball %s %s\n' "$1" "$2" >> "$calls"
        case "$2" in
            *nvim-linux-arm64.tar.gz) return 0 ;;
            *) return 1 ;;
        esac
    }
    install_nvim_appimage() {
        printf 'appimage %s %s\n' "$1" "$2" >> "$calls"
        return 1
    }

    install_nvim >/dev/null 2>&1 ||
        fail "aarch64 nvim install should use arm64 release asset"
    grep -q 'nvim-linux-arm64.tar.gz' "$calls" ||
        fail "aarch64 nvim install did not use arm64 release asset"
)

test_pre_commit_no_staged_files() (
    git -C "$DIR" diff --cached --quiet || return 0
    "$DIR/.githooks/pre-commit" || fail "pre-commit failed with no staged files"
)

test_pre_commit_blocks_secrets() (
    local tmp clone hook
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    clone="$tmp/clone"
    hook="$DIR/.githooks/pre-commit"
    git init -q "$clone"
    cd "$clone" || fail "cd to $clone failed"

    # 1) text blob containing an OpenAI-shaped key must be blocked
    printf 'OPENAI_API_KEY=sk-proj-%s\n' "$(printf 'a%.0s' {1..40})" > leaky.env
    git add leaky.env
    if "$hook" >/dev/null 2>&1; then
        fail "pre-commit should block file containing sk-proj-... token"
    fi
    git reset -q HEAD -- leaky.env
    rm -f leaky.env

    # 2) OpenAI project keys use the URL-safe alphabet, including _ and -
    printf 'OPENAI_API_KEY=%s%s\n' 'sk-proj-' 'abc_DEF-0123456789abc_DEF-0123456789' > leaky.env
    git add leaky.env
    if "$hook" >/dev/null 2>&1; then
        fail "pre-commit should block OpenAI project token with _ and -"
    fi
    git reset -q HEAD -- leaky.env
    rm -f leaky.env

    # 3) key-shaped filename must be blocked even when content looks innocuous
    printf 'not actually a key\n' > server.pem
    git add server.pem
    if "$hook" >/dev/null 2>&1; then
        fail "pre-commit should block file with .pem extension"
    fi
    git reset -q HEAD -- server.pem
    rm -f server.pem

    # 4) benign content with sk- prefix but only 8 chars must NOT be blocked
    printf 'see anchor sk-foo123\n' > notes.md
    git add notes.md
    if ! "$hook" >/dev/null 2>&1; then
        fail "pre-commit should NOT block short sk- string in markdown"
    fi
)

test_theme_detection() (
    # Stage detect-theme.sh at the path the function calls into
    # ($HOME/.local/bin/detect-theme), pointed at a tmp HOME so we don't
    # touch the developer's real $HOME.
    local tmp_home
    tmp_home="$(mktemp -d)"
    trap 'rm -rf "$tmp_home"' EXIT
    mkdir -p "$tmp_home/.local/bin"
    ln -s "$DIR/scripts/detect-theme.sh" "$tmp_home/.local/bin/detect-theme"
    chmod +x "$DIR/scripts/detect-theme.sh"

    local fn
    fn="$(sed -n '/^_dotfiles_detect_theme() {/,/^}/p' "$DIR/shell/bashrc_exports")"
    [ -n "$fn" ] || fail "could not extract _dotfiles_detect_theme from bashrc_exports"

    local out
    # TMUX=fake skips the OSC 11 probe inside detect-theme so the test doesn't
    # write to the suite-runner's controlling tty.

    # Pre-set override wins over every fallback.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" TMUX=fake DOTFILES_THEME=light \
        bash -c "$fn"'; _dotfiles_detect_theme; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "light" ] || fail "pre-set override not honoured: got '$out'"

    # COLORFGBG dark bg → dark.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" TMUX=fake COLORFGBG='15;0' \
        bash -c "$fn"'; _dotfiles_detect_theme; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "dark" ] || fail "COLORFGBG=15;0 should resolve dark: got '$out'"

    # COLORFGBG light bg → light.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" TMUX=fake COLORFGBG='0;15' \
        bash -c "$fn"'; _dotfiles_detect_theme; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "light" ] || fail "COLORFGBG=0;15 should resolve light: got '$out'"

    # No tty, no COLORFGBG, non-darwin → falls through to dark.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" TMUX=fake OSTYPE=linux-gnu \
        bash -c "$fn"'; _dotfiles_detect_theme; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "dark" ] || fail "fallback should be dark: got '$out'"

    # Helper missing → bashrc function still falls back to dark.
    out="$(env -i HOME="$(mktemp -d)" PATH="$PATH" TMUX=fake \
        bash -c "$fn"'; _dotfiles_detect_theme; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "dark" ] || fail "missing helper should still yield dark: got '$out'"

    # VS Code Remote-SSH storage.json → light themeBackground resolves light.
    # Staged at $tmp_home/.vscode-server/... so detect-theme.sh's loop hits it.
    mkdir -p "$tmp_home/.vscode-server/data/User/globalStorage"
    printf '{"themeBackground":"#ffffff"}\n' \
        > "$tmp_home/.vscode-server/data/User/globalStorage/storage.json"
    out="$(env -i HOME="$tmp_home" PATH="$PATH" TMUX=fake TERM_PROGRAM=vscode \
        bash -c "$fn"'; _dotfiles_detect_theme; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "light" ] || fail "Remote-SSH storage.json white bg should resolve light: got '$out'"

    # VS Code Remote-SSH storage.json → dark themeBackground resolves dark.
    printf '{"themeBackground":"#1e1e1e"}\n' \
        > "$tmp_home/.vscode-server/data/User/globalStorage/storage.json"
    out="$(env -i HOME="$tmp_home" PATH="$PATH" TMUX=fake TERM_PROGRAM=vscode \
        bash -c "$fn"'; _dotfiles_detect_theme; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "dark" ] || fail "Remote-SSH storage.json dark bg should resolve dark: got '$out'"

    # Clean up so subsequent assertions don't inherit the staged file.
    rm -rf "$tmp_home/.vscode-server"
)

test_theme_function() (
    # The `theme` function lives in bashrc_aliases and depends on
    # _dotfiles_detect_theme from bashrc_exports. Extract both, source in
    # order, then exercise light/dark/auto. No tmux integration tested here —
    # the function guards `tmux set-environment` on `$TMUX`, and we run with
    # TMUX unset (env -i) so that branch is a no-op.
    local tmp_home
    tmp_home="$(mktemp -d)"
    trap 'rm -rf "$tmp_home"' EXIT
    mkdir -p "$tmp_home/.local/bin"
    ln -s "$DIR/scripts/detect-theme.sh" "$tmp_home/.local/bin/detect-theme"
    chmod +x "$DIR/scripts/detect-theme.sh"

    local detect_fn theme_fn
    detect_fn="$(sed -n '/^_dotfiles_detect_theme() {/,/^}/p' "$DIR/shell/bashrc_exports")"
    theme_fn="$(sed -n '/^theme() {/,/^}/p' "$DIR/shell/bashrc_aliases")"
    [ -n "$detect_fn" ] || fail "could not extract _dotfiles_detect_theme"
    [ -n "$theme_fn" ] || fail "could not extract theme function"

    local out
    # `theme light` forces DOTFILES_THEME=light regardless of detection.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" \
        bash -c "$detect_fn"$'\n'"$theme_fn"';
            theme light >/dev/null 2>&1; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "light" ] || fail "theme light should set DOTFILES_THEME=light: got '$out'"

    # `theme dark` forces DOTFILES_THEME=dark.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" \
        bash -c "$detect_fn"$'\n'"$theme_fn"';
            theme dark >/dev/null 2>&1; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "dark" ] || fail "theme dark should set DOTFILES_THEME=dark: got '$out'"

    # `theme auto` clears any cached value and re-runs detection. With
    # COLORFGBG=0;15 the fallback chain resolves to light — proves the
    # DOTFILES_THEME unset path actually re-enters detection.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" COLORFGBG='0;15' \
        DOTFILES_THEME=dark \
        bash -c "$detect_fn"$'\n'"$theme_fn"';
            theme auto >/dev/null 2>&1; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "light" ] || fail "theme auto should re-detect (COLORFGBG=0;15 → light): got '$out'"

    # Unknown argument exits non-zero without modifying state.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" DOTFILES_THEME=light \
        bash -c "$detect_fn"$'\n'"$theme_fn"';
            theme bogus 2>/dev/null; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "light" ] || fail "theme bogus should not modify DOTFILES_THEME: got '$out'"
)

_theme_auto_setup() {
    # Common scaffolding for the two theme-auto tests: tmp HOME with a
    # detect-theme symlink and a tmux stub that logs every invocation and
    # answers `display -p '#{client_theme}'` / `-V` from env vars.
    local tmp_home="$1"
    mkdir -p "$tmp_home/.local/bin"
    ln -s "$DIR/scripts/detect-theme.sh" "$tmp_home/.local/bin/detect-theme"
    chmod +x "$DIR/scripts/detect-theme.sh"
    cat > "$tmp_home/.local/bin/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_STUB_LOG"
if [ "$1" = "display" ] && [ "$2" = "-p" ] && [ "$3" = '#{client_theme}' ]; then
    printf '%s\n' "${TMUX_STUB_CLIENT_THEME:-}"
elif [ "$1" = "-V" ]; then
    printf 'tmux %s\n' "${TMUX_STUB_VERSION:-3.2a}"
fi
exit 0
STUB
    chmod +x "$tmp_home/.local/bin/tmux"
}

test_theme_function_auto_busts_cache_on_modern_tmux() (
    # On tmux 3.6+ (where #{client_theme} returns light/dark), `theme auto`
    # busts the stale DOTFILES_THEME from tmux's global env so the
    # re-probe doesn't immediately return the value cached by an earlier
    # run.
    local tmp_home
    tmp_home="$(mktemp -d)"
    trap 'rm -rf "$tmp_home"' EXIT
    _theme_auto_setup "$tmp_home"

    local detect_fn theme_fn
    detect_fn="$(sed -n '/^_dotfiles_detect_theme() {/,/^}/p' "$DIR/shell/bashrc_exports")"
    theme_fn="$(sed -n '/^theme() {/,/^}/p' "$DIR/shell/bashrc_aliases")"
    [ -n "$detect_fn" ] || fail "could not extract _dotfiles_detect_theme"
    [ -n "$theme_fn" ] || fail "could not extract theme function"

    local log="$tmp_home/tmux.log"
    : > "$log"
    env -i HOME="$tmp_home" PATH="$tmp_home/.local/bin:$PATH" \
        TMUX=fake TMUX_STUB_LOG="$log" \
        TMUX_STUB_CLIENT_THEME=light TMUX_STUB_VERSION=3.6 \
        DOTFILES_THEME=dark \
        bash -c "$detect_fn"$'\n'"$theme_fn"';
            theme auto >/dev/null 2>&1' >/dev/null 2>&1 || true

    grep -E '^set-environment .*-u .*DOTFILES_THEME' "$log" >/dev/null ||
        fail "theme auto did not bust tmux global env cache on tmux 3.6+. log:
$(cat "$log")"
)

test_theme_function_auto_refuses_on_legacy_tmux() (
    # On tmux < 3.6 there's no in-session probe (#{client_theme} is empty,
    # passthrough unavailable). `theme auto` must refuse rather than bust
    # the cache and overwrite it with the dark default that detect-theme
    # would fall through to.
    local tmp_home
    tmp_home="$(mktemp -d)"
    trap 'rm -rf "$tmp_home"' EXIT
    _theme_auto_setup "$tmp_home"

    local detect_fn theme_fn
    detect_fn="$(sed -n '/^_dotfiles_detect_theme() {/,/^}/p' "$DIR/shell/bashrc_exports")"
    theme_fn="$(sed -n '/^theme() {/,/^}/p' "$DIR/shell/bashrc_aliases")"

    local log="$tmp_home/tmux.log"
    local stderr_file="$tmp_home/stderr.txt"
    : > "$log"
    env -i HOME="$tmp_home" PATH="$tmp_home/.local/bin:$PATH" \
        TMUX=fake TMUX_STUB_LOG="$log" \
        TMUX_STUB_CLIENT_THEME='' TMUX_STUB_VERSION=3.2a \
        DOTFILES_THEME=dark \
        bash -c "$detect_fn"$'\n'"$theme_fn"';
            theme auto >/dev/null 2> "'"$stderr_file"'"' || true

    ! grep -E '^set-environment .*-u .*DOTFILES_THEME' "$log" >/dev/null ||
        fail "theme auto wrongly busted cache on legacy tmux. log:
$(cat "$log")"
    grep -q 'not supported' "$stderr_file" ||
        fail "theme auto did not emit unsupported-tmux warning on legacy tmux. stderr:
$(cat "$stderr_file")"
)

test_chpc_allocs_self_test() (
    python3 "$DIR/scripts/chpc-allocs.py" --self-test >/dev/null ||
        fail "chpc-allocs.py --self-test failed"
)

test_chpc_allocs_python36_compatible() (
    if ! command -v python3.6 >/dev/null 2>&1; then
        printf 'SKIP: test_chpc_allocs_python36_compatible (python3.6 not found)\n'
        return 0
    fi
    python3.6 "$DIR/scripts/chpc-allocs.py" --self-test >/dev/null ||
        fail "chpc-allocs.py --self-test failed under python3.6"
)

# Each ai/skills/<name>/SKILL.md must have YAML frontmatter starting on
# line 1, contain a `name:` field matching the directory, and a non-empty
# `description:`. Catches typos and missing fields that would break skill
# discovery once symlinked into ~/.claude/skills/.
test_skill_files_have_valid_frontmatter() (
    local skills_dir="$DIR/ai/skills" skill_dir name skill_file
    local declared_name declared_description closing_line

    [ -d "$skills_dir" ] || fail "ai/skills/ directory is missing"

    local count=0
    for skill_dir in "$skills_dir"/*/; do
        [ -d "$skill_dir" ] || continue
        name="$(basename "$skill_dir")"
        skill_file="${skill_dir}SKILL.md"
        [ -f "$skill_file" ] || fail "$name: SKILL.md is missing"

        if [ "$(sed -n '1p' "$skill_file")" != "---" ]; then
            fail "$name: SKILL.md must start with YAML frontmatter on line 1"
        fi

        closing_line="$(awk 'NR > 1 && /^---$/ { print NR; exit }' "$skill_file")"
        if [ -z "$closing_line" ]; then
            fail "$name: SKILL.md frontmatter is missing closing ---"
        fi

        declared_name="$(awk '/^---$/{f++; next} f==1 && /^name:/ {sub(/^name:[[:space:]]*/, ""); print; exit}' "$skill_file")"
        declared_description="$(awk '/^---$/{f++; next} f==1 && /^description:/ {sub(/^description:[[:space:]]*/, ""); print; exit}' "$skill_file")"

        if [ "$declared_name" != "$name" ]; then
            fail "$name: frontmatter name='$declared_name' does not match directory '$name'"
        fi
        if [ -z "$declared_description" ]; then
            fail "$name: frontmatter description is empty"
        fi
        count=$((count + 1))
    done

    [ "$count" -gt 0 ] || fail "no skills found under $skills_dir"
)

# install_claude_skills.sh must (a) parse cleanly under bash and (b)
# honor --dry-run by NOT touching ~/.local/share/claude-skills or
# ~/.claude/skills (no clones, no symlinks). Catches accidental drift in
# the DRY_RUN contract enforced by lib/common.sh::run_step.
test_install_claude_skills_dry_run() (
    local tmp script
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    script="$DIR/scripts/install_claude_skills.sh"

    bash -n "$script" || fail "install_claude_skills.sh syntax error"

    local output step
    output="$(HOME="$tmp" bash "$script" --dry-run 2>&1)" || \
        fail "install_claude_skills.sh --dry-run returned non-zero"

    # Every curated repo must be planned, including the single-skill repos
    # that go through link_skill_path rather than link_skill.
    for step in "clone superpowers" "clone anthropic-skills" \
                "clone research-paper-writing-skills" "link research-paper-writing" \
                "clone skill-deslop" "link deslop" \
                "clone mattpocock-skills" "link grilling" \
                "clone structured-analytic-skills" "link premortem-analysis"; do
        printf '%s\n' "$output" | grep -qF "Would run: $step" ||
            fail "install_claude_skills.sh --dry-run did not plan '$step'"
    done

    if [ -d "$tmp/.local/share/claude-skills" ]; then
        fail "install_claude_skills.sh --dry-run created cache directory"
    fi
    if [ -d "$tmp/.claude/skills" ]; then
        fail "install_claude_skills.sh --dry-run created skills directory"
    fi
    return 0
)

# sync_agent_skills.sh --dry-run must create nothing under a throwaway HOME
# while still reporting the links it would make in both directions.
test_sync_agent_skills_dry_run() (
    local tmp script output
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    script="$DIR/scripts/sync_agent_skills.sh"
    bash -n "$script" || fail "sync_agent_skills.sh syntax error"

    mkdir -p "$tmp/.claude/skills/foo" "$tmp/.codex/skills/bar"
    : > "$tmp/.claude/skills/foo/SKILL.md"
    : > "$tmp/.codex/skills/bar/SKILL.md"

    output="$(HOME="$tmp" CODEX_HOME="$tmp/.codex" bash "$script" --dry-run 2>&1)" ||
        fail "sync_agent_skills.sh --dry-run returned non-zero: $output"
    printf '%s\n' "$output" | grep -q 'Would run: agents/skills:foo' ||
        fail "dry-run did not report the Claude -> Codex link"
    printf '%s\n' "$output" | grep -q 'Would run: claude/skills:bar' ||
        fail "dry-run did not report the Codex -> Claude link"
    [ ! -e "$tmp/.agents" ] || fail "dry-run created ~/.agents"
    [ ! -e "$tmp/.claude/skills/bar" ] || fail "dry-run created ~/.claude/skills/bar"
)

# Real run under a throwaway HOME: links both ways, skips what it must, is
# idempotent (no .bak), and prunes only its own broken links.
test_sync_agent_skills_links_both_ways() (
    local tmp script out
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    script="$DIR/scripts/sync_agent_skills.sh"
    export HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex"

    mkdir -p "$HOME/.claude/skills/foo" "$HOME/.claude/skills/synced/s" \
             "$HOME/.claude/skills/taken" "$HOME/.agents/skills/taken" \
             "$HOME/.codex/skills/bar" "$HOME/.codex/skills/.system/sys" \
             "$HOME/.codex/skills/nodoc" "$tmp/elsewhere"
    : > "$HOME/.claude/skills/foo/SKILL.md"
    : > "$HOME/.claude/skills/synced/s/SKILL.md"
    : > "$HOME/.claude/skills/taken/SKILL.md"
    : > "$HOME/.codex/skills/bar/SKILL.md"
    : > "$HOME/.codex/skills/.system/sys/SKILL.md"
    ln -s "$tmp/elsewhere/gone" "$HOME/.agents/skills/alien"   # broken, not ours

    bash "$script" >/dev/null || fail "first sync run failed"

    [ -L "$HOME/.agents/skills/foo" ] || fail "foo not mirrored to ~/.agents/skills"
    [ "$(portable_realpath "$HOME/.agents/skills/foo")" = "$(portable_realpath "$HOME/.claude/skills/foo")" ] ||
        fail ".agents/skills/foo points at the wrong target"
    [ -L "$HOME/.claude/skills/bar" ] || fail "bar not mirrored to ~/.claude/skills"
    [ "$(portable_realpath "$HOME/.claude/skills/bar")" = "$(portable_realpath "$HOME/.codex/skills/bar")" ] ||
        fail ".claude/skills/bar points at the wrong target"
    [ ! -e "$HOME/.agents/skills/bar" ] || fail "Codex-native skill was mirrored back into ~/.agents/skills"
    [ ! -e "$HOME/.agents/skills/synced" ] || fail "synced dir was mirrored"
    [ ! -e "$HOME/.claude/skills/.system" ] || fail ".system was mirrored"
    [ ! -e "$HOME/.claude/skills/nodoc" ] || fail "dir without SKILL.md was mirrored"
    if [ ! -d "$HOME/.agents/skills/taken" ] || [ -L "$HOME/.agents/skills/taken" ]; then
        fail "real directory at destination was clobbered"
    fi
    [ -L "$HOME/.agents/skills/alien" ] || fail "broken link outside managed roots was removed"

    out="$(bash "$script" 2>&1)" || fail "second sync run failed"
    if printf '%s\n' "$out" | grep -q 'Backing up'; then
        fail "second run backed something up"
    fi
    [ -z "$(find "$HOME/.agents" "$HOME/.claude/skills" -name '*.bak*' 2>/dev/null)" ] ||
        fail "second run produced .bak files"

    rm -rf "$HOME/.codex/skills/bar" "$HOME/.claude/skills/foo"
    bash "$script" >/dev/null || fail "prune run failed"
    [ ! -L "$HOME/.claude/skills/bar" ] || fail "broken Codex -> Claude link not pruned"
    [ ! -L "$HOME/.agents/skills/foo" ] || fail "broken Claude -> Codex link not pruned"
)

# uninstall.sh must remove the sync links (root sweep through unlink_config)
# while leaving the real skill directories on both sides alone.
test_uninstall_removes_agent_skill_links() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    export HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex"
    mkdir -p "$HOME/.claude/skills/foo" "$HOME/.codex/skills/bar" "$HOME/.dotfiles-generated"
    : > "$HOME/.claude/skills/foo/SKILL.md"
    : > "$HOME/.codex/skills/bar/SKILL.md"
    bash "$DIR/scripts/sync_agent_skills.sh" >/dev/null || fail "sync failed"
    [ -L "$HOME/.agents/skills/foo" ] || fail "precondition: ~/.agents/skills/foo missing"
    [ -L "$HOME/.claude/skills/bar" ] || fail "precondition: ~/.claude/skills/bar missing"

    # shellcheck source=uninstall.sh
    . "$DIR/uninstall.sh"
    # lib/common.sh was sourced at the top of this file with the real $HOME
    # and is guarded against re-sourcing, so re-point the roots at the
    # throwaway HOME (uninstall.sh reads them at call time).
    CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
    CODEX_AGENT_SKILLS_DIR="$HOME/.agents/skills"
    CODEX_HOME_SKILLS_DIR="$HOME/.codex/skills"

    remove_symlinks >/dev/null
    [ ! -L "$HOME/.agents/skills/foo" ] || fail ".agents/skills/foo survived uninstall"
    [ ! -L "$HOME/.claude/skills/bar" ] || fail ".claude/skills/bar survived uninstall"
    [ -d "$HOME/.claude/skills/foo" ] || fail "uninstall removed a real Claude skill dir"
    [ -d "$HOME/.codex/skills/bar" ] || fail "uninstall removed a real Codex skill dir"
    [ ! -d "$HOME/.agents" ] || fail "empty ~/.agents was not removed"
)

test_agent_writing_guidance_preserves_global_instructions() (
    local tmp codex_dir
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    export HOME="$tmp/home" CODEX_HOME="$tmp/codex-profile"
    codex_dir="$CODEX_HOME"
    mkdir -p "$HOME/.claude/rules" "$codex_dir"
    printf '# Local storage rules\nKeep large files off root.\n' > "$HOME/.claude/CLAUDE.md"
    printf '# Existing Claude writing rule\nKeep this style.\n' > "$HOME/.claude/rules/writing.md"
    printf '# Existing Codex guidance\n\nKeep this instruction.\n' > "$codex_dir/AGENTS.md"
    printf '# Temporary override\nKeep this too.\n' > "$codex_dir/AGENTS.override.md"
    cp "$codex_dir/AGENTS.md" "$tmp/original-agents"
    cp "$codex_dir/AGENTS.override.md" "$tmp/original-override"
    cp "$HOME/.claude/CLAUDE.md" "$tmp/original-claude"
    cp "$HOME/.claude/rules/writing.md" "$tmp/original-claude-rule"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    link_agent_writing_guidance >/dev/null || fail "writing guidance install failed"
    link_agent_writing_guidance >/dev/null || fail "writing guidance reinstall failed"

    [ -L "$HOME/.claude/rules/writing.md" ] || fail "Claude writing rule not linked"
    [ "$(portable_realpath "$HOME/.claude/rules/writing.md")" = "$DIR/ai/writing-guidance.md" ] ||
        fail "Claude writing rule points at the wrong source"
    [ "$(grep -Fxc "$WRITING_BLOCK_BEGIN" "$codex_dir/AGENTS.md")" -eq 1 ] ||
        fail "Codex guidance duplicated in AGENTS.md"
    [ "$(grep -Fxc "$WRITING_BLOCK_BEGIN" "$codex_dir/AGENTS.override.md")" -eq 1 ] ||
        fail "Codex guidance duplicated in AGENTS.override.md"
    grep -Fq 'Keep this instruction.' "$codex_dir/AGENTS.md" ||
        fail "Codex install removed existing instructions"

    bash -c '. "$1/uninstall.sh"; remove_agent_writing_guidance' _ "$DIR" >/dev/null ||
        fail "writing guidance uninstall failed"
    cmp -s "$HOME/.claude/rules/writing.md" "$tmp/original-claude-rule" ||
        fail "existing Claude writing rule was not restored"
    cmp -s "$codex_dir/AGENTS.md" "$tmp/original-agents" || fail "Codex instructions changed after uninstall"
    cmp -s "$codex_dir/AGENTS.override.md" "$tmp/original-override" || fail "Codex override changed after uninstall"
    cmp -s "$HOME/.claude/CLAUDE.md" "$tmp/original-claude" || fail "Claude user guidance changed"

    printf '%s\n%s\n' "$WRITING_BLOCK_END" "$WRITING_BLOCK_BEGIN" >> "$codex_dir/AGENTS.md"
    cp "$codex_dir/AGENTS.md" "$tmp/malformed-agents"
    if link_agent_writing_guidance >/dev/null 2>&1; then
        fail "writing guidance accepted misordered markers"
    fi
    cmp -s "$codex_dir/AGENTS.md" "$tmp/malformed-agents" ||
        fail "writing guidance changed a file with misordered markers"
)

test_agent_writing_guidance_restores_global_symlink() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    export HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex"
    mkdir -p "$CODEX_HOME" "$tmp/external"
    printf '# External guidance\n' > "$tmp/external/AGENTS.md"
    ln -s "$tmp/external/AGENTS.md" "$CODEX_HOME/AGENTS.md"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    link_agent_writing_guidance >/dev/null || fail "writing guidance link install failed"
    [ -L "$CODEX_HOME/AGENTS.md.bak" ] || fail "existing Codex link was not backed up"
    [ -f "$CODEX_HOME/AGENTS.md" ] && [ ! -L "$CODEX_HOME/AGENTS.md" ] ||
        fail "Codex guidance did not become a merged file"
    grep -Fq '# External guidance' "$CODEX_HOME/AGENTS.md" ||
        fail "existing linked instructions were not kept active"
    grep -Fq "$WRITING_BLOCK_BEGIN" "$CODEX_HOME/AGENTS.md" ||
        fail "new writing guidance was not merged"

    bash -c '. "$1/uninstall.sh"; remove_agent_writing_guidance' _ "$DIR" >/dev/null ||
        fail "writing guidance link uninstall failed"
    [ "$(readlink "$CODEX_HOME/AGENTS.md")" = "$tmp/external/AGENTS.md" ] ||
        fail "original Codex link was not restored"
    [ ! -e "$CODEX_HOME/AGENTS.md.bak" ] || fail "Codex backup remained after restore"

    rm "$CODEX_HOME/AGENTS.md"
    link_agent_writing_guidance >/dev/null || fail "writing guidance fresh install failed"
    [ -L "$CODEX_HOME/AGENTS.md" ] || fail "fresh Codex AGENTS.md was not linked"
    bash -c '. "$1/uninstall.sh"; remove_agent_writing_guidance' _ "$DIR" >/dev/null ||
        fail "writing guidance fresh uninstall failed"
    [ ! -e "$CODEX_HOME/AGENTS.md" ] || fail "fresh Codex guidance survived uninstall"
)

test_update_guard_decisions() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    export HOME="$tmp/home"; mkdir -p "$HOME"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    # shellcheck disable=SC2034 # consumed by update_guard
    FORCE=false
    # shellcheck disable=SC2034 # consumed by update_guard
    NO_UPDATE=false

    # A present tool reporting version 1.2.3 (a shell function is resolvable by
    # command -v and callable as "$cmd --version", so it stands in for a binary).
    ftool() { echo "ftool 1.2.3"; }

    [ "$(tool_version ftool)" = "1.2.3" ] || fail "tool_version did not extract 1.2.3"

    # Missing command -> (re)install (return 1).
    if update_guard nope nope-missing-cmd 9.9.9 >/dev/null; then
        fail "update_guard skipped a missing tool"
    fi
    # Present and current -> skip (return 0).
    update_guard ftool ftool 1.2.3 >/dev/null || fail "update_guard did not skip a current tool"
    # Installed newer than 'latest' -> skip.
    update_guard ftool ftool 1.0.0 >/dev/null || fail "update_guard did not skip a newer-than-latest tool"
    # Outdated -> install (return 1).
    if update_guard ftool ftool 2.0.0 >/dev/null; then
        fail "update_guard skipped an outdated tool"
    fi
    # Latest unknown (empty) -> keep current (return 0), never churn.
    update_guard ftool ftool "" >/dev/null || fail "update_guard did not keep tool on unknown latest"
    # Non-numeric / v-prefixed tag is normalized ("v2.0.0" -> outdated -> install).
    if update_guard ftool ftool v2.0.0 >/dev/null; then
        fail "update_guard did not normalize a v-prefixed latest"
    fi
    # A jq-style tag ("jq-1.7.1") equal to current -> skip.
    ftool() { echo "ftool 1.7.1"; }
    update_guard ftool ftool jq-1.7.1 >/dev/null || fail "update_guard did not normalize a jq-style tag"

    # --force always (re)installs, even when current.
    ftool() { echo "ftool 1.2.3"; }
    # shellcheck disable=SC2034
    FORCE=true
    if update_guard ftool ftool 1.2.3 >/dev/null; then
        fail "update_guard skipped despite --force"
    fi
    # shellcheck disable=SC2034
    FORCE=false
    # --no-update skips even when outdated.
    # shellcheck disable=SC2034
    NO_UPDATE=true
    update_guard ftool ftool 99.0.0 >/dev/null || fail "update_guard did not honor --no-update"
)

test_install_accepts_no_update_flag() (
    local out
    # --no-update is parsed (sets the flag) before --help short-circuits, so this
    # exits 0 with usage text and must never fall through to "Unknown option".
    out="$(bash "$DIR/install.sh" --no-update --help 2>&1)" ||
        fail "install.sh --no-update --help did not exit 0"
    printf '%s\n' "$out" | grep -q -- '--no-update' ||
        fail "install.sh --help does not document --no-update"
    if printf '%s\n' "$out" | grep -q 'Unknown option'; then
        fail "install.sh treated --no-update as an unknown option"
    fi
)

run_test() {
    local name="$1"

    if ! "$name"; then
        fail "$name failed"
    fi
}

main() {
    run_test test_remote_bash_lc_quote
    run_test test_portable_helpers
    run_test test_backup_helpers_fail_loudly
    run_test test_backup_rotation_preserves_edited_bak
    run_test test_backup_rotation_idempotent_when_identical
    run_test test_remote_capture_strips_banner
    run_test test_gh_latest_cache_memoizes
    run_test test_cached_init_handles_empty_output
    run_test test_cached_init_evals_output_when_cache_unwritable
    run_test test_manifest_controls_uninstall
    run_test test_detect_theme_installs_to_local_bin
    run_test test_codex_mcp_bridge_installs_to_local_bin
    run_test test_tmux_clipboard_compat_uses_global_scope
    run_test test_claude_statusline
    run_test test_codex_mcp_bridge_protocol
    run_test test_scripts_source_without_side_effects
    run_test test_deploy_sources_without_prompting
    run_test test_remote_dotfiles_preflight_snippet
    run_test test_git_clone_command_uses_gh_only_for_credentials
    run_test test_remote_git_probe_snippet
    run_test test_auth_state_helpers
    run_test test_rclone_config_helpers
    run_test test_rclone_deploy_merges_only_gdrive
    run_test test_rclone_install_uses_managed_local_bin
    run_test test_setup_dry_run_is_non_mutating
    run_test test_chpc_config_rendering_uses_repo_files
    run_test test_chpc_module_loads_initialize_module_command
    run_test test_module_var_reset_clears_stale_values
    run_test test_nvim_manifest_records_only_owned_layout
    run_test test_nvim_install_selects_legacy_and_arm_assets
    run_test test_pre_commit_no_staged_files
    run_test test_pre_commit_blocks_secrets
    run_test test_theme_detection
    run_test test_theme_function
    run_test test_theme_function_auto_busts_cache_on_modern_tmux
    run_test test_theme_function_auto_refuses_on_legacy_tmux
    run_test test_chpc_allocs_self_test
    run_test test_chpc_allocs_python36_compatible
    run_test test_skill_files_have_valid_frontmatter
    run_test test_install_claude_skills_dry_run
    run_test test_sync_agent_skills_dry_run
    run_test test_sync_agent_skills_links_both_ways
    run_test test_uninstall_removes_agent_skill_links
    run_test test_agent_writing_guidance_preserves_global_instructions
    run_test test_agent_writing_guidance_restores_global_symlink
    run_test test_update_guard_decisions
    run_test test_install_accepts_no_update_flag
    echo "All regression tests passed."
}

main "$@"
