# GitHub Actions integration

Run Ralph audits in CI against your MCP server, on a schedule or on demand.

## Quick start (drop-in for any MCP repo)

In your MCP repo, create `.github/workflows/audit.yml`:

```yaml
name: Weekly Ralph audit

on:
  schedule:
    - cron: '0 4 * * 0'   # 04:00 UTC every Sunday
  workflow_dispatch:

jobs:
  audit:
    uses: gacabartosz/mcp-ralph-audit/.github/workflows/audit-mcp-reusable.yml@main
    with:
      mcp-cmd: 'uv run mcp-zus'
      prompt-path: 'audit/PROMPT.md'
      max-iterations: 30
      max-cost: '20.00'
      model: claude-opus-4-7
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

Add `audit/PROMPT.md` to your repo (use [`prompts/audit-mcp-zus.md`](../prompts/audit-mcp-zus.md) as a template).

Add `ANTHROPIC_API_KEY` to your repo's GitHub Actions secrets (Settings → Secrets and variables → Actions → New repository secret). Note: this is **required** because GitHub Actions has no `claude auth login` keychain — pay-per-token billing applies inside CI.

## What the workflow does

1. **Checkout** your repo with full history.
2. **Install** `uv`, Claude Code CLI, and `ralph-claude-code`.
3. **Run** `ralph audit-mcp` with your `mcp-cmd` and `prompt-path`.
4. **Render** `RALPH_AUDIT_REPORT.md` from the run artifacts.
5. **Upload** all artifacts (transcript, TOOLS_AUDIT, ISSUES, COVERAGE, fix_plan) for 90 days.
6. **Open a PR** with `RALPH_AUDIT_REPORT.md` on a branch named `ralph/audit-<run_id>`.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `mcp-cmd` | yes | — | Shell command that spawns your MCP server (stdio). |
| `prompt-path` | yes | — | Path to PROMPT.md inside the calling repo. |
| `max-iterations` | no | 30 | Hard iteration cap. |
| `max-cost` | no | `'20.00'` | Hard cost cap in USD (string). |
| `model` | no | `claude-opus-4-7` | Claude model alias or full name. |
| `ralph-version` | no | `git+...@main` | Pip spec for ralph-claude-code (pin to a tag for stability). |

## Secrets

| Secret | Required | Description |
|---|---|---|
| `anthropic-api-key` | yes | Anthropic API key for `claude -p` (pay-per-token in CI). |

## Cost considerations

- Default `--max-cost 20.00` caps each audit at $20 of API usage.
- Weekly schedule × $20 = $80/month worst-case for a single MCP repo.
- Drop `model` to `claude-sonnet-4-6` if you want cheaper audits with similar quality for surface checks.
- Use `workflow_dispatch` instead of `schedule` if you only want manual audits.

## What you get out

After each successful run:

1. **PR** on your repo with `RALPH_AUDIT_REPORT.md` — review and merge if you want it tracked in main.
2. **Artifact** for 90 days containing the full transcript and audit files — download from the workflow run page.
3. **Branch** `ralph/audit-<run_id>` — keep or delete after review.

## Pinning the version

For reproducible audits, pin `ralph-version`:

```yaml
with:
  mcp-cmd: 'uv run mcp-zus'
  prompt-path: 'audit/PROMPT.md'
  ralph-version: 'git+https://github.com/gacabartosz/mcp-ralph-audit.git@v0.1.0'
```

(Pin to a tag once we publish releases.)

## Local dry-run before enabling CI

Before letting the workflow run weekly with budget, rehearse locally:

```bash
uv run mcp-ralph audit-mcp \
    --mcp-cmd 'uv run mcp-zus' \
    --prompt audit/PROMPT.md \
    --repo . \
    --max-iterations 5 \
    --max-cost 5.00 \
    --branch ralph/local-test
```

If that produces a sensible `TOOLS_AUDIT.md` on a small budget, the CI version with the full $20 budget will produce a thorough audit.
