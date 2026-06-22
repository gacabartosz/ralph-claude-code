# Implementation Status Summary

**Last Updated**: 2026-06-22
**Version**: v0.11.5
**Overall Status**: Original roadmap (Phases 1–6) complete and merged. Active work has moved to the
multi-provider epic (`#312`–`#327`) plus standalone enhancements.

> **Reconciled to reality (2026-06-22).** This document was previously stuck at v0.9.8 / "Phase 1 in
> progress" / 276 tests. The repository is in fact at **v0.11.5** with **691 tests** and every issue in
> the original 6-phase roadmap closed upstream. The sections below reflect the actual code and the
> current open issues.

---

## Current State

### Test Coverage

| Metric | Current | Notes |
|--------|---------|-------|
| **Total Tests** | 691 | Counted from `@test` declarations across all bats files |
| **Unit Tests** | 523 | `tests/unit/` (22 files) |
| **Integration Tests** | 168 | `tests/integration/` (7 files) |
| **E2E Tests** | 0 | Planned with the v2 web UI (Playwright) |
| **Pass Rate (Linux CI)** | 100% | GitHub Actions is the enforced quality gate |

> **Host caveat (macOS):** On a macOS dev host (bash 3.2.57 + BSD coreutils) 4 tests fail and 8 do not
> run, all for host-specific reasons — BSD `stat`, `/usr/bin/osascript` present, GNU-only `head -n -1`,
> and bash-3.2 `source <(process-substitution)`. These are **not** code regressions; the Linux CI gate
> stays 100% green. A "make the bats suite macOS-portable" task is tracked in `.ralph/fix_plan.md`.

### Test Files (29 files, 691 tests)

**Unit (`tests/unit/`, 523):**

| File | Tests |
|------|-------|
| test_cli_modern.bats | 129 |
| test_json_parsing.bats | 56 |
| test_exit_detection.bats | 54 |
| test_enable_core.bats | 38 |
| test_cli_parsing.bats | 35 |
| test_session_continuity.bats | 26 |
| test_rate_limiting.bats | 25 |
| test_ralph_enable.bats | 24 |
| test_task_sources.bats | 23 |
| test_circuit_breaker_recovery.bats | 22 |
| test_wizard_utils.bats | 20 |
| test_file_protection.bats | 15 |
| test_integrity_check.bats | 10 |
| test_backup_rollback.bats | 8 |
| test_jsonl_guard.bats | 6 |
| test_status_updates.bats | 6 |
| test_log_rotation.bats | 5 |
| test_notifications.bats | 5 |
| test_safe_count.bats | 5 |
| test_dry_run.bats | 4 |
| test_metrics_tracking.bats | 4 |
| test_session_id_corruption.bats | 3 |

**Integration (`tests/integration/`, 168):**

| File | Tests |
|------|-------|
| test_project_setup.bats | 50 |
| test_prd_import.bats | 33 |
| test_edge_cases.bats | 25 |
| test_loop_execution.bats | 20 |
| test_tmux_integration.bats | 17 |
| test_installation.bats | 15 |
| test_monitor.bats | 8 |

### Code Quality

- **CI/CD**: ✅ GitHub Actions operational (`test.yml`, `claude.yml`, `claude-code-review.yml`)
- **Response Analyzer**: ✅ `lib/response_analyzer.sh` (JSON parsing, session management, question detection)
- **Circuit Breaker**: ✅ `lib/circuit_breaker.sh` (three-state + cooldown/auto-reset recovery)
- **Date / Timeout / Log utilities**: ✅ `lib/date_utils.sh`, `lib/timeout_utils.sh`, `lib/log_utils.sh`
- **Enable tooling**: ✅ `lib/enable_core.sh`, `lib/wizard_utils.sh`, `lib/task_sources.sh`
- **File protection**: ✅ `lib/file_protection.sh` (integrity validation every loop)

---

## Phase Status — Original Roadmap (Phases 1–6): ✅ COMPLETE

All issues from the original six-phase plan are closed upstream and merged. Verified by `gh issue view`
and by grepping the implementation.

### Phase 1: CLI Modernization — ✅ Complete
- [x] #28 Modern CLI commands · #29 JSON response parsing · #30 session management · #31 ralph-import CLI
- [x] #48 shell-escaping security fix · #50 `--allowed-tools` validation
- [x] #10/#11/#12/#13 CLI/installation/project-setup/PRD-import tests
- [x] #24/#25/#26/#27 TESTING.md, CONTRIBUTING.md, README testing instructions, badges
- [x] #51 Session expiration for `.claude_session_id` (Phase 1.5)

### Phase 2: Agent SDK Integration — ✅ Complete (closed)
- [x] #32 SDK proof of concept · #33 custom tools · #34 hybrid CLI/SDK architecture · #35 migration docs

### Phase 3: Configuration & Infrastructure — ✅ Complete
- [x] #18 log rotation (`lib/log_utils.sh`, `rotate_logs`) · #19 dry-run mode · #20 `.ralphrc` config support
- [x] #21 metrics & analytics (`track_metrics`, `ralph-stats`) · #22 notifications (`send_notification`)
- [x] #23 backup & rollback (`create_backup`) · #223 token-based rate limiting (`MAX_TOKENS_PER_HOUR`)
- [x] #228 `CLAUDE_MODEL`/`CLAUDE_EFFORT` overrides · #211 `RALPH_SHELL_INIT_FILE`

### Phase 4: Validation Testing — ✅ Complete
- [x] #14 tmux integration tests (17) · #15 monitor dashboard tests (8) · #16 status update tests (6)

### Phase 5: GitHub Issue Integration — ✅ Complete (closed)
- [x] #69 import plan from GitHub issue · #71 filter/select by metadata · #72 batch/queue · #73 lifecycle
      (`lib/task_sources.sh`)

### Phase 6: Sandbox Execution — ✅ Complete (closed)
- [x] #74 local Docker sandbox · #75 E2B cloud sandbox · #78 generic sandbox interface
      (`SANDBOX_PROVIDER`/`SANDBOX_DOCKER_*`/E2B hooks in `.ralphrc` + `ralph_loop.sh`)

### Hardening / community bug fixes (v0.10 → v0.11.5)
- [x] #134/#199 `is_error:true` detection · #208 remove `set -e` · #190 question detection + version check
- [x] #194 stale-exit-signal prevention · #198 productive-timeout detection · #100 Extra Usage quota
- [x] #224 suppress heuristic exit in JSON mode · #216/#188 live/monitor fixes · #101 permission-denial
- [x] #250 truncated-JSONL guard · #254 `--resume` session corruption · #255/#251/#260 `_safe_count` · #256 post-completion crash

---

## Active Roadmap — Multi-Provider Epic (`#312`–`#327`)

The current development thrust is making Ralph provider-agnostic (today it is Claude-only). **Not yet
started** in code: `lib/agents/` does not exist and `AGENT_PROVIDER` is unimplemented.

| Issue | Phase | Title |
|-------|-------|-------|
| #312 | P1.1 | Command-construction seam: `lib/agents/` registry + Claude reference adapter |
| #313 | P1.2 | Output-normalization seam: internal analysis struct + Claude parser |
| #314 | P1.3 | Provider selection: `AGENT_PROVIDER` config + CLI + tmux forwarding |
| #315 | P2.1 | Capabilities matrix + graceful feature degradation |
| #316 | P2.2 | Generic adapter test harness (mock CLIs) |
| #317 | P3.1 | Codex adapter (pilot) |
| #318 | P4.1 | Gemini adapter |
| #319 | P4.2 | OpenCode adapter |
| #320 | P4.3 | Droid adapter |
| #321 | P4.4 | Kilocode adapter |
| #322 | P4.5 | Copilot adapter (text-only, degraded) |
| #323 | P5.1 | Sandbox provider-awareness (docker/e2b wrap any provider) |
| #324 | P5.2 | Monitor + `status.json` provider surfacing |
| #325 | P5.3 | Docs sweep: provider matrix, setup guides, CLAUDE.md, templates |
| #327 | P8.1 | Recompile triage-incoming-issues workflow lock (CI/infra) |

### Standalone Enhancements (open)

| Issue | Title |
|-------|-------|
| #213 | `KEEP_MONITOR_AFTER_EXIT` — preserve tmux session after loop exits |
| #163 | Monorepo-aware features for multi-service architectures |
| #157 | Nix flake support for reproducible installation |
| #156 | Windows support (PowerShell/CMD wrappers, Windows Terminal monitoring) |
| #138 | Automate version and test-count badges via GitHub Actions |
| #110 | Token cost tracking |
| #102 | Plan-limit exhaustion handling |

### Internal (dogfood) follow-ups
- Make the bats suite macOS-portable (see host caveat above) — tracked in `.ralph/fix_plan.md`.

---

## Summary Statistics

| Category | Count |
|----------|-------|
| Version | v0.11.5 |
| Total Tests | 691 (523 unit + 168 integration) |
| Test Files | 29 |
| Linux CI Pass Rate | 100% |
| Original roadmap phases complete | 6 / 6 |
| Open multi-provider issues | 15 (`#312`–`#327`) |
| Open standalone enhancements | 7 |

**Status**: ✅ Mature, well-tested loop runner; original roadmap fully delivered.
**Next Steps**: Begin the multi-provider epic at the seam — `#312` (`lib/agents/` registry + Claude
reference adapter), which unblocks every downstream adapter.
