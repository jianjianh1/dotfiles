#!/usr/bin/env bash
set -uo pipefail

# Install a curated set of Claude Code plugins.
#
# Scope: one MCP server (`fetch`) plus three marketplace plugins
# (`context7`, `commit-commands`, `pr-review-toolkit`).
#
# Anything previously installed by older versions of this script
# (github/filesystem/memory/git/serena MCPs, and several marketplace
# plugins) gets pruned defensively so upgrade hosts converge to the
# current curated set on the next ./install.sh.

DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: install_claude_plugins.sh [--help|-h]
  -h, --help    Show this help
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

if ! command -v claude &>/dev/null; then
    echo "Error: claude CLI not found. Run install.sh first."
    exit 1
fi

CLAUDE_HAS_MCP=false
CLAUDE_HAS_PLUGIN_CMD=false
claude mcp --help >/dev/null 2>&1 && CLAUDE_HAS_MCP=true
claude plugin --help >/dev/null 2>&1 && CLAUDE_HAS_PLUGIN_CMD=true

FAILURES=()

# --- MCP servers -----------------------------------------------------------

# Idempotent MCP add: remove existing entry first so re-runs are clean.
mcp_add() {
    local name="$1"; shift
    claude mcp remove --scope user "$name" 2>/dev/null || true
    claude mcp add "$@"
}

# MCPs we used to register but no longer want. Removed defensively on each
# run so hosts upgrading from older configs converge cleanly.
#
# WARNING: these names are *reserved* by the installer. Don't `claude mcp add`
# a server with any of these names locally — it will be silently removed on
# the next ./install.sh. Use a different name for personal MCPs.
STALE_MCPS=(github filesystem memory git serena)

prune_stale_mcps() {
    $CLAUDE_HAS_MCP || return 0
    local listing name
    # One `mcp list` per run instead of per-entry — the command does live
    # health checks and can stall on slow networks.
    listing="$(claude mcp list 2>/dev/null || true)"
    [ -n "$listing" ] || return 0
    for name in "${STALE_MCPS[@]}"; do
        # Require `name: ` at line start — current Claude prints user-added
        # MCPs as "name: cmd - status". The colon anchor avoids matching
        # plugin-installed MCPs ("plugin:foo:name: ..."), which we don't own.
        if printf '%s\n' "$listing" | grep -qE "^${name}:[[:space:]]"; then
            claude mcp remove --scope user "$name" >/dev/null 2>&1 \
                && echo "  Removed stale MCP: $name"
        fi
    done
}

echo "Installing Claude Code MCP servers..."
prune_stale_mcps

if ! $CLAUDE_HAS_MCP; then
    echo "  Skipping MCP setup (this Claude Code build has no 'mcp' subcommand)."
elif command -v uvx &>/dev/null; then
    echo "  Adding Fetch MCP server..."
    run_step "mcp:fetch" mcp_add fetch --scope user --transport stdio fetch \
        -- uvx mcp-server-fetch
else
    echo "  Skipping Fetch MCP (uvx not found — install uv first)"
fi

echo ""
echo "Installed MCP servers:"
if $CLAUDE_HAS_MCP; then
    claude mcp list
else
    echo "  (skipped)"
fi

# --- Marketplace plugins ---------------------------------------------------

# `claude plugin enable` exits non-zero with "already enabled" on re-runs.
# Treat that one case as success.
enable_plugin_idempotent() {
    local spec="$1" out
    if out="$(claude plugin enable "$spec" 2>&1)"; then
        printf '%s\n' "$out"
        return 0
    fi
    if printf '%s' "$out" | grep -qi "already enabled"; then
        echo "Plugin \"$spec\" already enabled — skipping"
        return 0
    fi
    printf '%s\n' "$out" >&2
    return 1
}

refresh_marketplace() {
    claude plugin marketplace update "$1" >/dev/null 2>&1 || true
}

install_and_enable_plugin() {
    local plugin="$1" market="${2:-claude-plugins-official}"
    run_step "$plugin"        claude plugin install "$plugin@$market"
    run_step "$plugin-enable" enable_plugin_idempotent "$plugin@$market"
}

# Plugins we used to install but no longer want. Uninstalled defensively.
#
# WARNING: these names are *reserved* by the installer (see STALE_MCPS).
# Don't `claude plugin install` any of them locally — they get uninstalled
# on every ./install.sh run.
STALE_PLUGINS=(
    github linear sentry notion slack
    codex
    agent-sdk-dev
    clangd-lsp pyright-lsp typescript-lsp gopls-lsp rust-analyzer-lsp
    explanatory-output-style
)

prune_stale_plugins() {
    $CLAUDE_HAS_PLUGIN_CMD || return 0
    local listing name
    # Cache the listing — `claude plugin list` does work per call.
    listing="$(claude plugin list 2>/dev/null || true)"
    if [ -n "$listing" ]; then
        for name in "${STALE_PLUGINS[@]}"; do
            # Match the `❯ name@marketplace` row exactly (leading whitespace
            # + chevron + space + name + @). Avoids substring matches against
            # marketplace URLs or status text that future Claude versions
            # might add.
            if printf '%s\n' "$listing" | grep -qF " ${name}@"; then
                claude plugin uninstall "$name" >/dev/null 2>&1 \
                    && echo "  Uninstalled stale plugin: $name"
            fi
        done
    fi
    # Older Codex installs added an extra marketplace; drop it too.
    claude plugin marketplace remove openai-codex >/dev/null 2>&1 || true
    claude plugin marketplace remove codex-plugin-cc >/dev/null 2>&1 || true
    # Pre-rename hosts can carry `codex-plugin-cc@codex-plugin-cc` in
    # settings.json `enabledPlugins`; the marketplace removal above doesn't
    # always cascade. Scrub it out so Claude doesn't warn on every start.
    cleanup_legacy_codex_settings
}

# Best-effort scrub of legacy Codex entries from ~/.claude/settings.json.
# Idempotent — bails silently if the file or python3 is missing, or if the
# entries are already gone.
cleanup_legacy_codex_settings() {
    local settings="$HOME/.claude/settings.json"
    [ -f "$settings" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$settings" <<'PY' || true
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except Exception:
    sys.exit(0)
changed = False
enabled = data.get("enabledPlugins")
if isinstance(enabled, dict) and "codex-plugin-cc@codex-plugin-cc" in enabled:
    del enabled["codex-plugin-cc@codex-plugin-cc"]
    changed = True
markets = data.get("extraKnownMarketplaces")
if isinstance(markets, dict) and "codex-plugin-cc" in markets:
    del markets["codex-plugin-cc"]
    changed = True
if changed:
    path.write_text(json.dumps(data, indent=2) + "\n")
PY
}

echo ""
echo "Installing Claude Code marketplace plugins..."

if ! $CLAUDE_HAS_PLUGIN_CMD; then
    echo "  Skipping marketplace plugins (no 'plugin' subcommand)."
else
    prune_stale_plugins
    refresh_marketplace claude-plugins-official

    # context7: live API docs lookup for libraries.
    install_and_enable_plugin context7

    # Development workflows used directly by the user's commit/PR flow.
    install_and_enable_plugin commit-commands
    install_and_enable_plugin pr-review-toolkit
fi

# --- Summary ---------------------------------------------------------------
echo ""
if [ ${#FAILURES[@]} -gt 0 ]; then
    echo "Done with ${#FAILURES[@]} warning(s):"
    for f in "${FAILURES[@]}"; do
        echo "  - $f (non-critical)"
    done
else
    echo "Done! All curated plugins installed."
fi
