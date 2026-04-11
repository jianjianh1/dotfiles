#!/usr/bin/env bash
set -uo pipefail

# Install MCP servers (plugins) for Claude Code.
# Requires: claude CLI, npx (node), and optionally a GITHUB_PERSONAL_ACCESS_TOKEN.

if ! command -v claude &>/dev/null; then
    echo "Error: claude CLI not found. Run setup.sh first."
    exit 1
fi

HAS_NPX=true
if ! command -v npx &>/dev/null; then
    echo "Warning: npx not found — MCP servers requiring npx will be skipped."
    HAS_NPX=false
fi

# --- Error tracking ---
FAILURES=()

install_plugin() {
    local name="$1"; shift
    if ! "$@"; then
        FAILURES+=("$name")
    fi
}

echo "Installing Claude Code MCP servers..."

# --- GitHub ---
# Use provided token, or fall back to gh CLI auth
GH_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"
if [ -z "$GH_TOKEN" ] && command -v gh &>/dev/null; then
    GH_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [ -n "$GH_TOKEN" ] && $HAS_NPX; then
    echo "  Adding GitHub MCP server..."
    install_plugin "mcp:github" claude mcp add --scope user --transport stdio github \
        --env GITHUB_PERSONAL_ACCESS_TOKEN="$GH_TOKEN" \
        -- npx -y @modelcontextprotocol/server-github
elif [ -z "$GH_TOKEN" ]; then
    echo "  Skipping GitHub (run 'gh auth login' or set GITHUB_PERSONAL_ACCESS_TOKEN)"
else
    echo "  Skipping GitHub MCP (npx not found)"
fi

# --- Filesystem ---
if $HAS_NPX; then
    echo "  Adding Filesystem MCP server..."
    install_plugin "mcp:filesystem" claude mcp add --scope user --transport stdio filesystem \
        -- npx -y @modelcontextprotocol/server-filesystem "$HOME"
fi

# --- Memory ---
if $HAS_NPX; then
    echo "  Adding Memory MCP server..."
    install_plugin "mcp:memory" claude mcp add --scope user --transport stdio memory \
        -- npx -y @modelcontextprotocol/server-memory
fi

# --- Fetch ---
echo "  Adding Fetch MCP server..."
if command -v uvx &>/dev/null; then
    install_plugin "mcp:fetch" claude mcp add --scope user --transport stdio fetch \
        -- uvx mcp-server-fetch
else
    echo "    Skipping Fetch (uvx not found — install uv first)"
fi

# --- Git ---
echo "  Adding Git MCP server..."
if command -v uvx &>/dev/null; then
    install_plugin "mcp:git" claude mcp add --scope user --transport stdio git \
        -- uvx mcp-server-git
else
    echo "    Skipping Git (uvx not found — install uv first)"
fi

echo ""
echo "Done! Installed MCP servers:"
claude mcp list

# ===== Marketplace Plugins =====
echo ""
echo "Installing Claude Code marketplace plugins..."

# Integrations
install_plugin "github" claude plugin install github@claude-plugins-official
install_plugin "linear" claude plugin install linear@claude-plugins-official
install_plugin "sentry" claude plugin install sentry@claude-plugins-official
install_plugin "notion" claude plugin install notion@claude-plugins-official
install_plugin "slack" claude plugin install slack@claude-plugins-official

# Codex (OpenAI) — add marketplace then install
install_plugin "codex-marketplace" claude plugin marketplace add openai/codex-plugin-cc
install_plugin "codex" claude plugin install codex@openai-codex

# Development workflows
install_plugin "commit-commands" claude plugin install commit-commands@claude-plugins-official
install_plugin "pr-review-toolkit" claude plugin install pr-review-toolkit@claude-plugins-official

# Development tools
install_plugin "agent-sdk-dev" claude plugin install agent-sdk-dev@claude-plugins-official

# Code intelligence (LSPs)
install_plugin "clangd-lsp" claude plugin install clangd-lsp@claude-plugins-official
install_plugin "pyright-lsp" claude plugin install pyright-lsp@claude-plugins-official
install_plugin "typescript-lsp" claude plugin install typescript-lsp@claude-plugins-official
install_plugin "gopls-lsp" claude plugin install gopls-lsp@claude-plugins-official
install_plugin "rust-analyzer-lsp" claude plugin install rust-analyzer-lsp@claude-plugins-official

# Output styles
install_plugin "explanatory-output-style" claude plugin install explanatory-output-style@claude-plugins-official

# --- Summary ---
echo ""
if [ ${#FAILURES[@]} -gt 0 ]; then
    echo "Done with ${#FAILURES[@]} failure(s):"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
    exit 1
else
    echo "Done! All marketplace plugins installed."
fi
