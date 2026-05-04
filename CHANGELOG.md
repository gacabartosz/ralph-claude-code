# Changelog

All notable changes to mcp-ralph-audit. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Renamed
- Project renamed from `ralph-claude-code` to `mcp-ralph-audit` to disambiguate from the much-older [`frankbria/ralph-claude-code`](https://github.com/frankbria/ralph-claude-code) (8.9k stars, generic Ralph loop). Our project is specifically the MCP-audit harness — different scope, different audience.
- Python package: `ralph-claude-code` → `mcp-ralph-audit`.
- CLI entry point: `ralph` → `mcp-ralph` (the legacy `ralph` command name still resolves for now; will be dropped in a future minor version).
- GitHub repo URL: `gacabartosz/ralph-claude-code` → `gacabartosz/mcp-ralph-audit`.

### Added
- `ralph version` prints `ralph-claude-code v<version>`.
- `ralph init` bootstraps a canonical PROMPT.md skeleton (`--mission`, `--completion-signal`, `--overwrite`).
- `ralph runs` lists past runs from `<repo>/.ralph-runs/`, with `--clean-older-than N` to drop old run dirs.
- `scripts/file_issues.py` parses ISSUES.md from a finished audit run and files each `### Pn-NNN` block as a real GitHub issue via `gh issue create` (default severity P0,P1; supports `--dry-run`).
- `scripts/render_audit_report.py` collates transcript + TOOLS_AUDIT.md + ISSUES.md + COVERAGE.md + fix_plan.md + branch git log into a single `RALPH_AUDIT_REPORT.md`.
- `.github/workflows/audit-mcp-reusable.yml` — `workflow_call` target any MCP repo can consume to schedule autonomous audits in CI, with PR generation.
- `docs/mcp-audit-recipe.md` — end-to-end recipe walking through install, write PROMPT.md, run audit, render report, file issues, cleanup.
- `docs/github-actions.md` — reusable-workflow integration guide with cost expectations and pinning advice.
- `DEFAULT_DISALLOWED_TOOLS` in RunConfig blocks `Bash(git commit*)`, `git push/reset/checkout/rebase/merge`, `git branch -D`, `rm -rf`, `gh repo delete`, `gh release delete`. Wired through CLI to `claude -p --disallowedTools`.

### Changed
- `bare_mode` defaults to `False` (was `True`). `--bare` skips Claude Code keychain auth and requires `ANTHROPIC_API_KEY`. The previous default crashed every iteration with "Not logged in" for users on Claude Pro/Max subscriptions.
- Loop progress signal now tracks "HEAD moved" rather than "our runner committed". Under `--permission-mode acceptEdits`, the model frequently self-commits inside an iteration; previously this zeroed the `files_changed` counter and falsely tripped `no_op_streak`.

### Fixed
- `prompts/audit-mcp-zus.md` was missing from the initial commit (path in CLAUDE.md but file not written). Added.
- Real audit run against `gacabartosz/mcp-zus` v0.1.0 was cut short by the false `no_op_streak` after 5 iterations / $3.22; subsequent run with the fix reached at least 16 productive iterations / $11.08 with 0 errors and 0 false no-ops, finding 28/30 tools have empty `description` (P1-001).

## [0.1.0] — 2026-05-04

Initial public release.

### Core
- `ralph run` — generic Ralph loop, `--prompt`, `--max-iterations`, `--max-cost`, `--branch`, `--dry-run`.
- `ralph audit-mcp` — MCP test-harness specialization, `--mcp-cmd`, live tool discovery, augmented prompt, report skeletons.
- `ralph status <run-dir>` — Rich table of iterations from transcript.jsonl.
- `Budget` with iteration cap, USD cost cap, no-op-streak and error-streak circuit breakers.
- `worktree.create_worktree` / `commit_in_worktree` / `cleanup_worktree` — git worktree isolation.
- `state.State` — PROMPT.md + fix_plan.md + transcript.jsonl I/O.
- `exit_detect.is_complete` — dual-condition signal (explicit `EXIT_SIGNAL: true` + heuristic "all complete").
- `mcp_audit.client.McpStdioClient` — async stdio JSON-RPC client (initialize → tools/list → tools/call).
- `mcp_audit.prompts` / `mcp_audit.reporter` — augment PROMPT.md with live tool inventory; seed report skeletons.
- `--dry-run` returns stub responses for unit-testing the loop without API calls.
- 30 unit tests + 1 integration test (real MCP echo server).
- Pattern reference: <https://ghuntley.com/ralph/>.
