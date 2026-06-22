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
- [ ] R.3 — Rewrite `IMPLEMENTATION_STATUS.md` to reflect v0.11.5: correct version/date, real test count, mark merged Phase 3 items done (#18 log-rotation, #21 metrics, #22 notifications, #23 backup, #223 token-limit) and any Phase 6 sandbox progress (#74/#75 referenced in .ralphrc). Commit `docs(status): reconcile to v0.11.5`.
- [ ] R.4 — Append the genuinely-open issues (from R.2) below as granular `- [ ]` sub-steps, each with its own bats test requirement. Remove any item already done. Commit `docs(plan): refresh open work from real issues`.

## Phase 1.5 — finish Phase 1 (only if still open after R)
- [ ] 1.5.a — `#51` Session expiration for `.claude_session_id` — verify behavior in `lib/response_analyzer.sh`; add/adjust + bats in `test_session_continuity.bats`. (If already implemented, mark done in R.4.)

## Phase 2 — Agent SDK integration (P2; refine in R.4)
- [ ] 2.a — `#32` Agent SDK proof-of-concept (smallest viable: one SDK-driven iteration behind a flag), with a bats/integration smoke test.
- [ ] 2.b — `#33` Define custom tools for the SDK path.
- [ ] 2.c — `#34` Hybrid CLI/SDK architecture (CLI remains default; SDK opt-in).
- [ ] 2.d — `#35` Document SDK migration strategy.

## Phase 5 — GitHub issue integration (P4; refine in R.4)
- [ ] 5.a — `#69` Import a plan from a single GitHub issue → fix_plan items (extend `lib/task_sources.sh`), with bats.
- [ ] 5.b — `#71` Filter/select issues by label/assignee.
- [ ] 5.c — `#72` Batch/queue multiple issues.
- [ ] 5.d — `#73` Issue lifecycle/completion workflow.

## Phase 6 — Sandbox execution (P4; LIKELY PARTLY DONE — confirm in R)
- [ ] 6.a — Confirm Docker sandbox (`#74`) actual state vs `.ralphrc` `SANDBOX_PROVIDER` hooks; close gaps + bats.
- [ ] 6.b — E2B (`#75`) gaps if any.
- [ ] 6.c — `#78` Generic sandbox interface / plugin architecture.

## Notes
- Every feature MUST ship with bats tests and keep `npm test` 100% green (repo quality gate).
- If any item needs upstream/main/global-install changes → `[BLOCKED: needs human]`, do not attempt.

## Completed
- [x] Project enabled for Ralph (self-hosting dogfood bootstrap)
