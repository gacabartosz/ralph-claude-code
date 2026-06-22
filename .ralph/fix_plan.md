# fix_plan — ralph-claude-code (self-hosting / dogfood)

> ONE sub-step per loop. Pick the first `- [ ]`. Verify with `npm test` (100% green), commit + push
> to `fork`, then mark `- [x]`. Never touch the global install. See `.ralph/PROMPT.md` for guardrails.

## Phase R — Reconcile reality vs docs (DO THIS FIRST)
The docs (`IMPLEMENTATION_STATUS.md`, `IMPLEMENTATION_PLAN.md`) say v0.9.8 / Phase 1, but git is
**v0.11.5** with much of Phase 3 (and possibly Phase 6 sandbox) already merged. Do NOT implement
anything until the plan reflects reality.

- [x] R.1 — Run `npm test`; record the real current test count + pass rate (used in R.3). Read-only step.
  - **Result (2026-06-22, on macOS host: bash 3.2.57 + BSD coreutils):** 691 tests planned; 683 executed → **679 pass / 4 fail**; 8 not executed (test_monitor.bats setup errors out).
  - **All 12 anomalies are HOST-specific, NOT code regressions** — they pass on the Linux CI quality gate (bash 4+/5+, GNU coreutils):
    1. `test_log_rotation.bats` "BSD stat fallback" — the stub delegates to GNU `stat -c%s`, absent on BSD `stat`.
    2. `test_notifications.bats` "notify-send on Linux" — macOS ships `/usr/bin/osascript`; test keeps `/usr/bin` in PATH so it can't hide it.
    3. `test_ralph_enable.bats` ×2 (`.ralphrc` verification) — `source <(process-substitution)` does not define functions in bash 3.2.57.
    4. `test_monitor.bats` ×8 (0 run) — setup uses `head -n -1` (GNU-only; BSD `head` errors) + bash-3.2 process substitution.
  - **NOTE for R.4:** add a genuinely-open item "make bats suite macOS-portable" (replace `head -n -1` with `sed '$d'`, gate BSD-stat/osascript stubs, avoid `source <(...)` for function defs).
- [x] R.2 — Build the true open-work list: `gh issue list --state open` + `git log`; cross-check vs `IMPLEMENTATION_STATUS.md`. **Result (2026-06-22):**
  - **`IMPLEMENTATION_STATUS.md` is badly stale** — claims v0.9.8 / Phase 1 in progress / 276 tests / 11 files. Reality: **v0.11.5, 691 tests / 24 files** (R.1). Does not mention the multi-provider epic at all. → R.3 rewrites it.
  - **Confirmed DONE in code** (grep + closed upstream issues): `rotate_logs` (#18/#236), `track_metrics` (#21), `send_notification` (#22/#240), `create_backup` (#23/#241), `MAX_TOKENS_PER_HOUR` (#223), sandbox docker/e2b (`.ralphrc` config + ralph_loop.sh handling; #74/#75/#78).
  - **ALL phases in THIS fix_plan are already CLOSED upstream → stale, remove in R.4:** Phase 1.5 `#51` CLOSED; Phase 2 `#32–#35` CLOSED; Phase 5 `#69/#71/#72/#73` CLOSED; Phase 6 `#74/#75/#78` CLOSED.
  - **TRUE open work (upstream OPEN issues):**
    - **Multi-provider epic — the new dominant roadmap (UNSTARTED: `lib/agents/` absent, `AGENT_PROVIDER` unimplemented):** `#312` P1.1 command-construction seam (`lib/agents/` registry + Claude ref adapter), `#313` P1.2 output-normalization seam, `#314` P1.3 provider selection (`AGENT_PROVIDER` config + CLI + tmux), `#315` P2.1 capabilities matrix + degradation, `#316` P2.2 generic adapter test harness (mock CLIs), `#317` P3.1 Codex adapter pilot, `#318` P4.1 Gemini, `#319` P4.2 OpenCode, `#320` P4.3 Droid, `#321` P4.4 Kilocode, `#322` P4.5 Copilot, `#323` P5.1 sandbox provider-awareness, `#324` P5.2 monitor/status.json provider surfacing, `#325` P5.3 docs sweep, `#327` P8.1 recompile triage lock (CI).
    - **Standalone enhancements:** `#213` KEEP_MONITOR_AFTER_EXIT, `#163` monorepo-aware, `#157` Nix flake, `#156` Windows support, `#138` automate version/test badges, `#110` token cost tracking, `#102` Plan Limit Exhaustion.
    - **From R.1:** make the bats suite macOS-portable.
- [x] R.3 — Rewrote `IMPLEMENTATION_STATUS.md` to v0.11.5: date 2026-06-22, real count **691 tests** (523 unit + 168 integration, 29 files), marked original Phases 1–6 complete (#18/#19/#20/#21/#22/#23/#223 Phase 3; #51 Phase 1.5; #32–35 Phase 2; #69/71/72/73 Phase 5; #74/75/78 Phase 6), added the multi-provider epic (#312–327) + standalone enhancements as the active roadmap, and noted the macOS host caveat. Committed `docs(status): reconcile to v0.11.5`.
- [x] R.4 — Refreshed the open-work list from real upstream issues. **Result (2026-06-22, verified by grep before rewrite):**
  - **Removed (verified DONE in code, CLOSED upstream):** old Phase 1.5 `#51` session expiration (`SESSION_EXPIRATION_SECONDS=86400` + expiry check live in `lib/response_analyzer.sh:869-958`); old Phase 2 `#32–35` Agent SDK (superseded by the multi-provider epic below); old Phase 5 `#69/71/72/73` GitHub issue integration (`lib/task_sources.sh` has beads/GitHub/PRD import); old Phase 6 `#74/75/78` sandbox (`SANDBOX_PROVIDER` docker/e2b config in `.ralphrc:59-74` + ralph_loop.sh handling).
  - **Kept as genuinely OPEN** (verified unstarted: `lib/agents/` ABSENT, `AGENT_PROVIDER` unreferenced): multi-provider epic `#312–327`, standalone enhancements `#213/163/157/156/138/110/102`, and the R.1 macOS-portability fix. Listed below as granular sub-steps.
  - Committed `docs(plan): refresh open work from real issues`.

## Phase P0 — Self-hosting hygiene (quick win; do FIRST)
- [ ] P0.a — Make the bats suite macOS-portable so the dogfood host's `npm test` matches Linux CI (R.1 caveat). Replace `head -n -1` with `sed '$d'` in `tests/integration/test_monitor.bats` (lines ~24, ~230); gate the BSD-`stat` fallback test in `test_log_rotation.bats` and the `notify-send`/`osascript` test in `test_notifications.bats` so they skip on the absent platform; avoid `source <(process-substitution)` for function defs in `test_ralph_enable.bats` ×2 (use a temp-file source). **Bats:** the four affected files must pass on macOS (bash 3.2 + BSD coreutils) AND stay green on Linux CI; verify `test_monitor.bats`'s 8 tests now execute. Do NOT weaken assertions — only fix host portability.

## Phase MP — Multi-provider epic (dominant roadmap, UNSTARTED; `#312–327`)
> Big items: split further into sub-steps when picked (scope ≤6 files/loop). Each ships bats tests; `npm test` stays green.
- [ ] MP.1 — `#312` P1.1 command-construction seam: create `lib/agents/` registry + extract Claude CLI command-building into a reference adapter (no behavior change). **Bats:** new `test_agents_registry.bats` asserting the Claude adapter reproduces today's `build_claude_command` output byte-for-byte.
- [ ] MP.2 — `#313` P1.2 output-normalization seam: route response parsing through an adapter-provided normalizer (Claude adapter wraps current JSON/text parsing). **Bats:** adapter normalizer returns the same fields `response_analyzer.sh` produces today (regression fixtures).
- [ ] MP.3 — `#314` P1.3 provider selection: `AGENT_PROVIDER` config (`.ralphrc` + env), CLI flag, and tmux/monitor surfacing; defaults to `claude`. **Bats:** `test_cli_parsing.bats` flag parsing + default-to-claude + precedence (env > .ralphrc) tests.
- [ ] MP.4 — `#315` P2.1 capabilities matrix + graceful degradation when a provider lacks a feature (e.g. session continuity). **Bats:** capability lookup + degradation-path tests.
- [ ] MP.5 — `#316` P2.2 generic adapter test harness with mock provider CLIs. **Bats:** harness self-test proving a mock adapter can be driven end-to-end.
- [ ] MP.6 — `#317` P3.1 Codex adapter pilot (first real non-Claude adapter on the seam). **Bats:** Codex adapter command-construction + normalization against recorded fixtures (mock CLI).
- [ ] MP.7 — `#318` P4.1 Gemini adapter. **Bats:** as MP.6 (mock CLI fixtures).
- [ ] MP.8 — `#319` P4.2 OpenCode adapter. **Bats:** as MP.6.
- [ ] MP.9 — `#320` P4.3 Droid adapter. **Bats:** as MP.6.
- [ ] MP.10 — `#321` P4.4 Kilocode adapter. **Bats:** as MP.6.
- [ ] MP.11 — `#322` P4.5 Copilot adapter. **Bats:** as MP.6.
- [ ] MP.12 — `#323` P5.1 make sandbox execution provider-aware (carry `AGENT_PROVIDER` into docker/e2b paths). **Bats:** sandbox command includes the selected provider.
- [ ] MP.13 — `#324` P5.2 surface active provider in `ralph_monitor.sh` + `status.json`. **Bats:** `test_monitor.bats`/status tests assert the provider field renders.
- [ ] MP.14 — `#325` P5.3 docs sweep: README + CLAUDE.md + templates document multi-provider usage. **Bats:** n/a (docs); keep `npm test` green.
- [ ] MP.15 — `#327` P8.1 CI recompile/triage lock so adapters stay in sync. **Bats/CI:** workflow guard + a test asserting registry/adapter parity.

## Phase ENH — Standalone enhancements (independent; pick by priority)
- [ ] ENH.1 — `#213` `KEEP_MONITOR_AFTER_EXIT` option (leave tmux monitor pane up after the loop exits). **Bats:** config/flag parsing + behavior in `test_cli_parsing.bats`.
- [ ] ENH.2 — `#110` token cost tracking (extend existing token counting with $ cost per model). **Bats:** cost calc + reporting tests in `test_rate_limiting.bats`/`test_metrics_tracking.bats`.
- [ ] ENH.3 — `#138` automate version/test-count badges (script that regenerates README badges from source). **Bats:** badge-generator unit test.
- [ ] ENH.4 — `#102` Plan Limit Exhaustion handling (distinct from 5-hour rate limit). **Bats:** detection + recovery tests in `test_cli_modern.bats`.
- [ ] ENH.5 — `#163` monorepo-aware operation (per-package `.ralph/` or scoped runs). **Bats:** detection + scoping tests.
- [ ] ENH.6 — `#157` Nix flake for reproducible install. **Bats/CI:** flake builds; smoke check.
- [ ] ENH.7 — `#156` Windows support (WSL/Git-Bash compatibility audit). **Bats:** portability guards; document scope as `[BLOCKED: needs human]` if it needs a Windows host.

## Notes
- Every feature MUST ship with bats tests and keep `npm test` 100% green (repo quality gate).
- If any item needs upstream/main/global-install changes → `[BLOCKED: needs human]`, do not attempt.

## Completed
- [x] Project enabled for Ralph (self-hosting dogfood bootstrap)
