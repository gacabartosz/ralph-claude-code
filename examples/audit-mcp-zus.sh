#!/usr/bin/env bash
# Demo: audit gacabartosz/mcp-zus end-to-end with Ralph.
#
# Pre-req:
#   - mcp-zus cloned at /Users/gaca/projects/personal/mcp-zus
#   - claude CLI installed and authenticated
#   - uv installed
#
# Cost: capped at $20. Iterations: capped at 30. Wall time: ~30-60 min.

set -euo pipefail

MCP_PATH="${MCP_PATH:-/Users/gaca/projects/personal/mcp-zus}"

uv run mcp-ralph audit-mcp \
    --mcp-cmd "uv run --directory ${MCP_PATH} mcp-zus" \
    --prompt "$(dirname "$0")/../prompts/audit-mcp-zus.md" \
    --repo "${MCP_PATH}" \
    --model claude-opus-4-7 \
    --max-iterations 30 \
    --max-cost 20.00 \
    --branch "ralph/audit-$(date +%Y-%m-%d)"
