# fix_plan — ralph-claude-code (self-hosting / dogfood)

> ONE sub-step per loop. Pick the first `- [ ]`. Verify with `npm test` (100% green), commit + push
> to `fork`, then mark `- [x]`. Never touch the global install. See `.ralph/PROMPT.md` for guardrails.

## Phase R — Reconcile reality vs docs (DO THIS FIRST)
The docs (`IMPLEMENTATION_STATUS.md`, `IMPLEMENTATION_PLAN.md`) say v0.9.8 / Phase 1, but git is
**v0.11.5** with much of Phase 3 (and possibly Phase 6 sandbox) already merged. Do NOT implement
anything until the plan reflects reality.

- [ ] R.1 — Run `npm test`; record the real current test count + pass rate (used in R.3). Read-only step.
- [ ] R.2 — Build the true open-work list: `gh issue list --state open --limit 0` (read-only, upstream) and `git log --oneline -40`; cross-check against `IMPLEMENTATION_STATUS.md`. Identify which roadmap issues are ALREADY done in code (grep: `rotate_logs`, `track_metrics`, `send_notification`, `create_backup`, `MAX_TOKENS_PER_HOUR`, `SANDBOX_PROVIDER`).
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
