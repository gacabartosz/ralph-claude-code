# Recipe: audit any MCP server with Ralph

End-to-end walkthrough using `gacabartosz/mcp-zus` as a worked example.

## Pre-requisites

- Python 3.11+ and [`uv`](https://docs.astral.sh/uv/) installed
- Claude Code CLI authenticated (`claude auth login`) **OR** `ANTHROPIC_API_KEY` set
- `gh` CLI authenticated if you want to file resulting issues automatically
- The MCP server you want to audit, runnable as a single shell command (stdio)

## Step 1 — install ralph

```bash
git clone https://github.com/gacabartosz/mcp-ralph-audit.git
cd ralph-claude-code
uv sync --all-extras
```

Smoke check:

```bash
uv run mcp-ralph audit-mcp --dry-run \
    --mcp-cmd "echo fake" \
    --max-iterations 3 --max-cost 1.00
```

Should: create a temp worktree, simulate 3 iterations, hit the iteration cap, and exit cleanly.

## Step 2 — write your PROMPT.md

Use [`prompts/audit-mcp-zus.md`](../prompts/audit-mcp-zus.md) as a template; the canonical structure:

```markdown
# Mission: full audit of <repo-name>

You are a senior AI engineer auditing the `<repo-name>` MCP server end-to-end.

## Phase plan
1. Tool surface audit (schema, name, description per tool)
2. Per-tool smoke test (real `tools/call` with sample input)
3. README cross-check (does each ✅/🟡 claim hold up?)
4. Domain-specific deep dives (XSD validation, signing flow, ...)
5. Examples sanity check (run any examples/*.py)

## State files (in your worktree)
- `@fix_plan.md` — priority-sorted to-do; check off as you go.
- `@TOOLS_AUDIT.md` — append-only audit table, one row per tool.
- `@ISSUES.md` — proposed GitHub issues (markdown).
- `@COVERAGE.md` — checkmark matrix per tool.

## Rules
- Do ONE thing per iteration.
- DO NOT IMPLEMENT PLACEHOLDER OR SIMPLE IMPLEMENTATIONS.
- No fixes. If a tool misbehaves, document it in ISSUES.md and move on.
- Cite stderr/stdout evidence in every TOOLS_AUDIT row.

## Exit
When all tools have a verdict and all phases checked off,
output exactly the line: `EXIT_SIGNAL: true`
```

## Step 3 — run the audit

```bash
uv run mcp-ralph audit-mcp \
    --mcp-cmd "uv run --directory /path/to/your-mcp-repo your-mcp-cmd" \
    --prompt prompts/audit-your-mcp.md \
    --repo /path/to/your-mcp-repo \
    --model claude-opus-4-7 \
    --max-iterations 30 \
    --max-cost 20.00 \
    --branch ralph/audit-$(date +%Y-%m-%d) \
    --keep
```

What happens:

1. Ralph spawns your MCP server, calls `tools/list`, captures the inventory.
2. Augments your `PROMPT.md` with the live tool list.
3. Creates a fresh git worktree on a new branch (`ralph/audit-<date>`).
4. Drops `fix_plan.md` + report skeletons into the worktree.
5. Loops: `claude -p` → iteration commit → check budget → repeat.

Stop conditions (whichever fires first):

- `EXIT_SIGNAL: true` in claude output → status **complete**
- `--max-iterations` reached → status **iterations_exhausted**
- `--max-cost` reached → status **cost_exhausted**
- 3 consecutive no-op iterations → status **no_op_streak**
- 5 consecutive errors → status **error_streak**

## Step 4 — review while it runs

In another terminal:

```bash
uv run mcp-ralph status /path/to/your-mcp-repo/.ralph-runs/audit-XXXXXXXX
```

Shows a live Rich table of iterations, costs, durations, files changed.

Or list all runs:

```bash
uv run mcp-ralph runs --repo /path/to/your-mcp-repo
```

## Step 5 — render a final report

```bash
uv run python scripts/render_audit_report.py \
    --run-dir /path/to/your-mcp-repo/.ralph-runs/audit-XXXXXXXX \
    --worktree /path/to/your-mcp-repo/.ralph-worktrees/ralph_audit-... \
    --out /path/to/your-mcp-repo/RALPH_AUDIT_REPORT.md
```

This collates: transcript stats + TOOLS_AUDIT.md + ISSUES.md + COVERAGE.md + branch git log into one polished `RALPH_AUDIT_REPORT.md`. Commit it to your repo or paste it into a PR.

## Step 6 — file issues

```bash
# Dry-run first
uv run python scripts/file_issues.py \
    --issues-md /path/to/your-mcp-repo/.ralph-worktrees/ralph_audit-.../ISSUES.md \
    --repo gacabartosz/your-mcp-repo \
    --severity P0,P1 \
    --dry-run

# Real run
uv run python scripts/file_issues.py \
    --issues-md /path/to/.../ISSUES.md \
    --repo gacabartosz/your-mcp-repo \
    --severity P0,P1
```

Each `### Pn-NNN — Title` block in `ISSUES.md` becomes a real GitHub issue with labels.

## Step 7 — clean up

After review, if you want to drop the worktree and audit branch:

```bash
cd /path/to/your-mcp-repo
git worktree remove .ralph-worktrees/ralph_audit-...
git branch -D ralph/audit-XXXX
```

Old run directories can be cleaned in bulk:

```bash
uv run mcp-ralph runs --repo /path/to/your-mcp-repo --clean-older-than 30
```

## Cost expectations (Opus 4.7)

For a 30-tool MCP with reasonable code coverage:

| Iterations | Wall-clock | API cost equivalent |
|---|---|---|
| 5  | ~5 min  | ~$2-3   |
| 15 | ~25 min | ~$8-10  |
| 30 | ~45 min | ~$15-20 |

If you're on a Claude Pro/Max subscription, you don't pay per token — but you may hit the weekly Opus rate limit on long runs. Drop `--model` to `claude-sonnet-4-6` if so.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Not logged in · Please run /login` in transcript | Set `--no-bare` (default) or `ANTHROPIC_API_KEY` |
| `no_op_streak` early | Loosen `--no-circuit-breaker` or check fix_plan.md isn't stuck |
| Audit "completes" suspiciously fast | Look at `transcript.jsonl` for `rc != 0` — server might be crashing |
| `gh issue create` fails | Run `gh auth status`, ensure scope `repo` is granted |
| Worktree already exists error | `--keep` from prior run; remove it or pass new `--branch` |
