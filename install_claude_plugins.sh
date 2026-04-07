#!/usr/bin/env bash
set -uo pipefail

# Install MCP servers (plugins) for Claude Code.
# Requires: claude CLI, npx (node), and optionally a GITHUB_PERSONAL_ACCESS_TOKEN.

if ! command -v claude &>/dev/null; then
    echo "Error: claude CLI not found. Run setup.sh first."
    exit 1
fi

if ! command -v npx &>/dev/null; then
    echo "Error: npx not found. Install Node.js first."
    exit 1
fi

echo "Installing Claude Code MCP servers..."

# --- GitHub ---
# Use provided token, or fall back to gh CLI auth
GH_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"
if [ -z "$GH_TOKEN" ] && command -v gh &>/dev/null; then
    GH_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [ -n "$GH_TOKEN" ]; then
    echo "  Adding GitHub MCP server..."
    claude mcp add --scope user --transport stdio github \
        --env GITHUB_PERSONAL_ACCESS_TOKEN="$GH_TOKEN" \
        -- npx -y @modelcontextprotocol/server-github
else
    echo "  Skipping GitHub (run 'gh auth login' or set GITHUB_PERSONAL_ACCESS_TOKEN)"
fi

# --- Filesystem ---
echo "  Adding Filesystem MCP server..."
claude mcp add --scope user --transport stdio filesystem \
    -- npx -y @modelcontextprotocol/server-filesystem "$HOME"

# --- Memory ---
echo "  Adding Memory MCP server..."
claude mcp add --scope user --transport stdio memory \
    -- npx -y @modelcontextprotocol/server-memory

# --- Fetch ---
echo "  Adding Fetch MCP server..."
if command -v uvx &>/dev/null; then
    claude mcp add --scope user --transport stdio fetch \
        -- uvx mcp-server-fetch
else
    echo "    Skipping Fetch (uvx not found — install uv first)"
fi

# --- Git ---
echo "  Adding Git MCP server..."
if command -v uvx &>/dev/null; then
    claude mcp add --scope user --transport stdio git \
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
claude plugin install github@claude-plugins-official 2>/dev/null || true
claude plugin install linear@claude-plugins-official 2>/dev/null || true
claude plugin install sentry@claude-plugins-official 2>/dev/null || true
claude plugin install notion@claude-plugins-official 2>/dev/null || true
claude plugin install slack@claude-plugins-official 2>/dev/null || true

# Codex (OpenAI) — add marketplace then install
claude plugin marketplace add openai/codex-plugin-cc 2>/dev/null || true
claude plugin install codex@openai-codex 2>/dev/null || true

# Development workflows
claude plugin install commit-commands@claude-plugins-official 2>/dev/null || true
claude plugin install pr-review-toolkit@claude-plugins-official 2>/dev/null || true

# Development tools
claude plugin install agent-sdk-dev@claude-plugins-official 2>/dev/null || true

# Code intelligence (LSPs)
claude plugin install clangd-lsp@claude-plugins-official 2>/dev/null || true
claude plugin install pyright-lsp@claude-plugins-official 2>/dev/null || true
claude plugin install typescript-lsp@claude-plugins-official 2>/dev/null || true
claude plugin install gopls-lsp@claude-plugins-official 2>/dev/null || true
claude plugin install rust-analyzer-lsp@claude-plugins-official 2>/dev/null || true

# Output styles
claude plugin install explanatory-output-style@claude-plugins-official 2>/dev/null || true

echo "Done! Installed marketplace plugins."
