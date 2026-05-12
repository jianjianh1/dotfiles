#!/usr/bin/env bash
set -uo pipefail

# Install MCP servers (plugins) for Claude Code.
# Requires: claude CLI, npx (node), and optionally a GITHUB_PERSONAL_ACCESS_TOKEN.

DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

ALLOW_CHPC_MCP="${SERVER_CONFIGS_ALLOW_CHPC_MCP:-false}"

usage() {
    cat <<'EOF'
Usage: install_claude_plugins.sh [--allow-chpc] [--help|-h]
  --allow-chpc  Install on CHPC after required MCP approval
  -h, --help    Show this help

Set SERVER_CONFIGS_ALLOW_CHPC_MCP=true as an automation-friendly alternative
to --allow-chpc.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --allow-chpc) ALLOW_CHPC_MCP=true ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if is_chpc && [ "$ALLOW_CHPC_MCP" != true ]; then
    echo "CHPC detected: skipping MCP server installation."
    echo "MCP servers require CHPC approval — contact helpdesk@chpc.utah.edu."
    echo "After approval, re-run with --allow-chpc or SERVER_CONFIGS_ALLOW_CHPC_MCP=true."
    exit 0
fi

if ! command -v claude &>/dev/null; then
    echo "Error: claude CLI not found. Run setup.sh first."
    exit 1
fi

HAS_NPX=true
if ! command -v npx &>/dev/null; then
    echo "Warning: npx not found — MCP servers requiring npx will be skipped."
    HAS_NPX=false
fi

claude_supports_mcp() {
    claude mcp --help >/dev/null 2>&1
}

claude_supports_plugin_cmd() {
    claude plugin --help >/dev/null 2>&1 || claude plugins --help >/dev/null 2>&1
}

claude_supports_plugin_marketplace() {
    claude plugin marketplace --help >/dev/null 2>&1 || claude plugins marketplace --help >/dev/null 2>&1
}

claude_plugin_cmd() {
    if claude plugin --help >/dev/null 2>&1; then
        claude plugin "$@"
    else
        claude plugins "$@"
    fi
}

CLAUDE_HAS_MCP=false
CLAUDE_HAS_PLUGIN_CMD=false
CLAUDE_HAS_PLUGIN_MARKETPLACE=false

claude_supports_mcp && CLAUDE_HAS_MCP=true
claude_supports_plugin_cmd && CLAUDE_HAS_PLUGIN_CMD=true
claude_supports_plugin_marketplace && CLAUDE_HAS_PLUGIN_MARKETPLACE=true

# --- Error tracking ---
FAILURES=()

# Shared run_step (records to FAILURES array). Aliased to install_plugin
# so existing call-sites read naturally.
install_plugin() { run_step "$@"; }

# `claude plugin enable` exits 1 with "already enabled" on re-runs.
# Treat that one case as success so idempotent runs stay clean.
enable_plugin_idempotent() {
    local spec="$1"
    local out
    if out="$(claude_plugin_cmd enable "$spec" 2>&1)"; then
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

install_and_enable_plugin() {
    local plugin="$1" market="${2:-claude-plugins-official}"
    install_plugin "$plugin" claude_plugin_cmd install "$plugin@$market"
    install_plugin "$plugin-enable" enable_plugin_idempotent "$plugin@$market"
}

cleanup_stale_codex_plugin_state() {
    local settings_file="$HOME/.claude/settings.json"

    # Older Codex marketplace installs used a different marketplace/plugin id.
    # Remove that stale state so current installs use codex@openai-codex cleanly.
    if $CLAUDE_HAS_PLUGIN_MARKETPLACE; then
        claude_plugin_cmd marketplace remove codex-plugin-cc 2>/dev/null || true
    fi

    if [ -f "$settings_file" ] && command -v python3 &>/dev/null; then
        python3 - "$settings_file" <<'PY'
import json
import pathlib
import sys

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

marketplaces = data.get("extraKnownMarketplaces")
if isinstance(marketplaces, dict) and "codex-plugin-cc" in marketplaces:
    del marketplaces["codex-plugin-cc"]
    changed = True

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n")
PY
    fi
}

# Idempotent MCP server add: remove existing server first, then add
mcp_add() {
    local name="$1"; shift
    claude mcp remove --scope user "$name" 2>/dev/null || true
    claude mcp add "$@"
}

echo "Installing Claude Code MCP servers..."

if ! $CLAUDE_HAS_MCP; then
    echo "  Skipping MCP server setup (this Claude Code build has no 'mcp' subcommand)."
fi

# --- GitHub ---
# Use provided token, or fall back to gh CLI auth
GH_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"
if [ -z "$GH_TOKEN" ] && command -v gh &>/dev/null; then
    GH_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if ! $CLAUDE_HAS_MCP; then
    :
elif [ -n "$GH_TOKEN" ] && $HAS_NPX; then
    echo "  Adding GitHub MCP server..."
    install_plugin "mcp:github" mcp_add github --scope user --transport stdio github \
        --env GITHUB_PERSONAL_ACCESS_TOKEN="$GH_TOKEN" \
        -- npx -y @modelcontextprotocol/server-github
elif [ -z "$GH_TOKEN" ]; then
    echo "  Skipping GitHub (run 'gh auth login' or set GITHUB_PERSONAL_ACCESS_TOKEN)"
else
    echo "  Skipping GitHub MCP (npx not found)"
fi

# --- Filesystem ---
if $CLAUDE_HAS_MCP && $HAS_NPX; then
    echo "  Adding Filesystem MCP server..."
    install_plugin "mcp:filesystem" mcp_add filesystem --scope user --transport stdio filesystem \
        -- npx -y @modelcontextprotocol/server-filesystem "$HOME"
fi

# --- Memory ---
if $CLAUDE_HAS_MCP && $HAS_NPX; then
    echo "  Adding Memory MCP server..."
    install_plugin "mcp:memory" mcp_add memory --scope user --transport stdio memory \
        -- npx -y @modelcontextprotocol/server-memory
fi

# --- Fetch ---
echo "  Adding Fetch MCP server..."
if ! $CLAUDE_HAS_MCP; then
    echo "    Skipping Fetch (Claude Code MCP commands unavailable)"
elif command -v uvx &>/dev/null; then
    install_plugin "mcp:fetch" mcp_add fetch --scope user --transport stdio fetch \
        -- uvx mcp-server-fetch
else
    echo "    Skipping Fetch (uvx not found — install uv first)"
fi

# --- Git ---
echo "  Adding Git MCP server..."
if ! $CLAUDE_HAS_MCP; then
    echo "    Skipping Git (Claude Code MCP commands unavailable)"
elif command -v uvx &>/dev/null; then
    install_plugin "mcp:git" mcp_add git --scope user --transport stdio git \
        -- uvx mcp-server-git
else
    echo "    Skipping Git (uvx not found — install uv first)"
fi

echo ""
echo "Done! Installed MCP servers:"
if $CLAUDE_HAS_MCP; then
    claude mcp list
else
    echo "  (skipped)"
fi

# ===== Marketplace Plugins =====
echo ""
echo "Installing Claude Code marketplace plugins..."

if ! $CLAUDE_HAS_PLUGIN_CMD; then
    echo "  Skipping marketplace plugins (this Claude Code build has no 'plugin' command)."
else

# Integrations
install_and_enable_plugin github
install_and_enable_plugin linear
install_and_enable_plugin sentry
install_and_enable_plugin notion
install_and_enable_plugin slack

# Codex (OpenAI) — add marketplace then install
cleanup_stale_codex_plugin_state
if $CLAUDE_HAS_PLUGIN_MARKETPLACE; then
    install_plugin "codex-marketplace" claude_plugin_cmd marketplace add openai/codex-plugin-cc
    install_and_enable_plugin codex openai-codex
else
    echo "  Skipping Codex marketplace plugin (plugin marketplace subcommand unavailable)"
fi

# Development workflows
install_and_enable_plugin commit-commands
install_and_enable_plugin pr-review-toolkit

# Development tools
install_and_enable_plugin agent-sdk-dev

# Code intelligence (LSPs)
install_and_enable_plugin clangd-lsp
install_and_enable_plugin pyright-lsp
install_and_enable_plugin typescript-lsp
install_and_enable_plugin gopls-lsp
install_and_enable_plugin rust-analyzer-lsp

# Output styles
install_and_enable_plugin explanatory-output-style
fi

# --- Summary ---
echo ""
if [ ${#FAILURES[@]} -gt 0 ]; then
    echo "Done with ${#FAILURES[@]} warning(s):"
    for f in "${FAILURES[@]}"; do
        echo "  - $f (non-critical)"
    done
else
    echo "Done! All marketplace plugins installed."
fi
