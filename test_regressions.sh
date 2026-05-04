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

test_chpc_config_rendering_is_safe_without_tools() (
    local tmp claude_cfg codex_cfg bash_compat
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    export HOSTNAME="login1.chpc.utah.edu"
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
    mkdir -p "$HOME"

    # shellcheck source=setup.sh
    . "$DIR/setup.sh"
    mkdir -p "$GENERATED_DIR"
    render_compat_configs

    claude_cfg="$GENERATED_DIR/claude_settings.json"
    codex_cfg="$GENERATED_DIR/codex_config.toml"
    bash_compat="$GENERATED_DIR/bashrc_compat"

    [ "$CLAUDE_SETTINGS_MODE" = "chpc" ] ||
        fail "CHPC Claude settings should be generated even when claude is missing"
    [ "$CODEX_CONFIG_MODE" = "chpc" ] ||
        fail "CHPC Codex config should be generated even when codex is missing"

    grep -q '"defaultMode": "default"' "$claude_cfg" ||
        fail "CHPC Claude settings should use default permission mode"
    grep -q '"skipDangerousModePermissionPrompt": false' "$claude_cfg" ||
        fail "CHPC Claude settings should not skip dangerous prompts"
    grep -q '"sandbox": { "enabled": true' "$claude_cfg" ||
        fail "CHPC Claude settings should enable sandboxing"

    grep -q 'approval_policy = "untrusted"' "$codex_cfg" ||
        fail "CHPC Codex config should require approval for untrusted commands"
    grep -q 'sandbox_mode = "workspace-write"' "$codex_cfg" ||
        fail "CHPC Codex config should use a valid workspace sandbox mode"

    grep -q "alias claude='claude'" "$bash_compat" ||
        fail "CHPC bash compat should not add dangerous Claude alias flags"
    grep -q "alias codex='codex'" "$bash_compat" ||
        fail "CHPC bash compat should not add dangerous Codex alias flags"
)

test_chpc_module_loads_initialize_module_command() (
    local tmp bash_compat init_line claude_line codex_line
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    export HOSTNAME="login1.chpc.utah.edu"
    mkdir -p "$HOME"

    # shellcheck source=setup.sh
    . "$DIR/setup.sh"
    mkdir -p "$GENERATED_DIR"
    CLAUDE_MODULE="claude-code"
    CODEX_MODULE="codex"
    render_bash_compat

    bash_compat="$GENERATED_DIR/bashrc_compat"
    init_line="$(grep -n 'for init in /etc/profile.d/modules.sh' "$bash_compat" | cut -d: -f1)"
    claude_line="$(grep -n 'module load claude-code' "$bash_compat" | cut -d: -f1)"
    codex_line="$(grep -n 'module load codex' "$bash_compat" | cut -d: -f1)"

    [ -n "$init_line" ] || fail "module initialization block missing"
    [ -n "$claude_line" ] || fail "Claude module load missing"
    [ -n "$codex_line" ] || fail "Codex module load missing"
    [ "$init_line" -lt "$claude_line" ] ||
        fail "Claude module load should come after module initialization"
    [ "$init_line" -lt "$codex_line" ] ||
        fail "Codex module load should come after module initialization"
)

test_chpc_mcp_skip_and_override() (
    local tmp output
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    export HOSTNAME="login1.chpc.utah.edu"
    export PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    mkdir -p "$HOME" "$tmp/bin"

    output="$(bash "$DIR/install_claude_plugins.sh" 2>&1)" ||
        fail "CHPC MCP default skip should exit successfully"
    printf '%s\n' "$output" | grep -q 'CHPC detected: skipping MCP server installation.' ||
        fail "CHPC MCP default run should skip"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'case "$1" in' \
        '  --version) printf "fake claude\n"; exit 0 ;;' \
        '  mcp) [ "${2:-}" = "--help" ] && exit 1; [ "${2:-}" = "list" ] && exit 0; exit 1 ;;' \
        '  plugin|plugins) [ "${2:-}" = "--help" ] && exit 1; exit 1 ;;' \
        '  *) exit 1 ;;' \
        'esac' > "$tmp/bin/claude"
    chmod +x "$tmp/bin/claude"

    output="$(bash "$DIR/install_claude_plugins.sh" --allow-chpc 2>&1)" ||
        fail "CHPC MCP --allow-chpc should continue with fake Claude: $output"
    printf '%s\n' "$output" | grep -q 'Installing Claude Code MCP servers...' ||
        fail "CHPC MCP --allow-chpc did not continue past CHPC guard"

    output="$(SERVER_CONFIGS_ALLOW_CHPC_MCP=true bash "$DIR/install_claude_plugins.sh" 2>&1)" ||
        fail "CHPC MCP env override should continue with fake Claude: $output"
    printf '%s\n' "$output" | grep -q 'Installing Claude Code MCP servers...' ||
        fail "CHPC MCP env override did not continue past CHPC guard"
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
    test_auth_state_helpers
    test_setup_dry_run_is_non_mutating
    test_chpc_config_rendering_is_safe_without_tools
    test_chpc_module_loads_initialize_module_command
    test_chpc_mcp_skip_and_override
    test_pre_commit_no_staged_files
    echo "All regression tests passed."
}

main "$@"
