#!/usr/bin/env bash
set -euo pipefail

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
claude mcp add --scope user --transport stdio fetch \
    -- npx -y @modelcontextprotocol/server-fetch

# --- Git ---
echo "  Adding Git MCP server..."
claude mcp add --scope user --transport stdio git \
    -- npx -y @modelcontextprotocol/server-git

echo ""
echo "Done! Installed MCP servers:"
claude mcp list
