# CLAUDE.md — mcp-ralph-audit

Ralph-loop pattern (Geoffrey Huntley, https://ghuntley.com/ralph/) specialized as
a Python CLI for **auditing MCP servers**. Cost caps, git worktree isolation,
autonomous audit mode with GitHub Actions reusable workflow.

Different from [`frankbria/ralph-claude-code`](https://github.com/frankbria/ralph-claude-code)
which is a generic Ralph runner — this one is purpose-built around `audit-mcp`.

## Build & Run

```bash
# Setup
uv sync --all-extras

# Smoke test (no API calls)
uv run mcp-ralph audit-mcp --dry-run --mcp-cmd "echo fake" --max-iterations 3 --max-cost 1

# Tests + lint
uv run pytest tests/unit -v --cov=ralph
uv run ruff check src/ tests/
uv run mypy src/

# Real run on mcp-zus (uses real API, costs money)
uv run mcp-ralph audit-mcp \
    --mcp-cmd "uv run --directory /Users/gaca/projects/personal/mcp-zus mcp-zus" \
    --prompt prompts/audit-mcp-zus.md \
    --model claude-opus-4-7 \
    --max-iterations 30 \
    --max-cost 20.00 \
    --branch ralph/audit-mcp-zus
```

## Architecture

```
src/ralph/
├── cli.py            # Typer CLI entry — `ralph run`, `ralph audit-mcp`, `ralph status`
├── loop.py           # core run_loop() — heart of Ralph
├── runner.py         # subprocess wrapper around `claude -p --output-format json`
├── budget.py         # Budget — cost cap, iteration cap, circuit breaker
├── worktree.py       # git worktree create/cleanup
├── state.py          # PROMPT.md / fix_plan.md / report.md I/O + transcript
├── exit_detect.py    # dual-condition: regex EXIT_SIGNAL + heuristics
├── config.py         # RunConfig pydantic model + env loading
├── mcp_audit/
│   ├── client.py     # stdio JSON-RPC client (initialize, tools/list, tools/call)
│   ├── prompts.py    # prompt template generators
│   └── reporter.py   # generate TOOLS_AUDIT.md / ISSUES.md / COVERAGE.md
└── observability/
    ├── logger.py     # JSONL transcript per iteration
    └── telemetry.py  # OTEL opt-in
```

## Code Conventions

- Python 3.11+ with `from __future__ import annotations`.
- Pydantic v2 for typed config / records.
- Typer for CLI. Rich for terminal output.
- Logs go to stderr; JSONL transcript goes to `.ralph-runs/<run-id>/transcript.jsonl`.
- Subprocess: always pass `cwd=`, `timeout=`, `env=` explicitly.
- Never call `git push` from code — push is human-only.
- Never run untrusted shell strings — use list-form `subprocess.run([...])`.

## Safety

- Hard cost cap (default $20). After that — refuse to start next iteration.
- Hard iteration cap (default 30 for audit-mcp). After that — refuse.
- Hard timeout per iteration (default 600s). After that — kill child process.
- Circuit breaker: 3× no-op iterations OR 5× error iterations → abort.
- Worktree isolation: every run creates a fresh `git worktree` under `.ralph-worktrees/<run-id>/`. Cleaned up on success unless `--keep`.
- Allowed tools whitelist passed to `claude -p --allowedTools`.
- Headless: `claude -p --bare --no-session-persistence --output-format json`.

## Owner

Bartosz Gaca — `gacabartosz`. Personal project. NOT BeeCommerce.
