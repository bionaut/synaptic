#!/usr/bin/env bash
# Starts browser-use MCP server with mcp-proxy bridging stdio → HTTP on port 8989.
#
# Prerequisites (one-time):
#   uv tool install mcp-proxy
#   uvx --from 'browser-use[cli]' python -m playwright install
#
# Usage:
#   cd sidecar/browser-use
#   cp .env.example .env   # fill in your OPENAI_API_KEY
#   ./start.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load .env
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

PORT="${BROWSER_USE_PORT:-8989}"
# Dev default: headed mode (visible browser). Override with BROWSER_USE_HEADLESS=true for headless.
export BROWSER_USE_HEADLESS="${BROWSER_USE_HEADLESS:-false}"
export BROWSER_USE_MODEL="gpt-4o-mini"

echo "Starting browser-use MCP sidecar on http://localhost:$PORT ..."
echo "  Streamable HTTP endpoint: http://localhost:$PORT/mcp"
echo "  SSE endpoint:             http://localhost:$PORT/sse"
echo "Press Ctrl+C to stop."

exec uvx mcp-proxy --transport streamablehttp --port "$PORT" -- \
  uvx --from 'browser-use[cli]' browser-use --mcp
