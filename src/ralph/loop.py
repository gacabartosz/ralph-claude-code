"""Core Ralph loop — heart of the harness."""
from __future__ import annotations

import logging
from dataclasses import dataclass
from enum import StrEnum
from itertools import count

from ralph import exit_detect, runner, worktree
from ralph.budget import BlockReason, Budget, IterationOutcome
from ralph.config import RunConfig
from ralph.state import State

log = logging.getLogger(__name__)


class RunStatus(StrEnum):
    COMPLETE = "complete"
    ITERATIONS_EXHAUSTED = "iterations_exhausted"
    COST_EXHAUSTED = "cost_exhausted"
    NO_OP_STREAK = "no_op_streak"
    ERROR_STREAK = "error_streak"
    INTERRUPTED = "interrupted"
    FAILED = "failed"


@dataclass
class RunResult:
    status: RunStatus
    iterations: int
    total_cost_usd: float
    branch: str
    worktree_path: str
    output_dir: str
    final_message: str = ""


def run(config: RunConfig) -> RunResult:
    """Execute the Ralph loop synchronously, return RunResult."""
    config.resolved_output_dir.mkdir(parents=True, exist_ok=True)

    if config.use_worktree:
        wt = worktree.create_worktree(
            base_repo=config.repo_path,
            branch=config.resolved_branch,
            worktree_root=config.resolved_worktree_root,
        )
    else:
        wt = worktree.Worktree(
            path=config.repo_path,
            branch=config.resolved_branch,
            base_repo=config.repo_path,
        )

    state = State.initialize(
        worktree_path=wt.path,
        output_dir=config.resolved_output_dir,
        prompt_path=config.prompt_path,
        completion_signal=config.completion_signal,
    )

    budget = Budget(
        max_iterations=config.max_iterations,
        max_cost_usd=config.max_cost_usd,
        no_op_streak_threshold=config.no_op_streak_threshold,
        error_streak_threshold=config.error_streak_threshold,
        circuit_breaker_enabled=config.circuit_breaker_enabled,
    )

    base_sha = worktree.head_sha(wt) if config.use_worktree else ""
    final_message = ""

    try:
        for iteration in count(1):
            allowed, reason = budget.can_start_next()
            if not allowed:
                final_message = f"budget gate blocked: {reason.value}"
                log.info("loop ending: %s", final_message)
                return _make_result(_status_from_reason(reason), budget, wt, config, final_message)

            prompt = state.compose_prompt(iteration)
            log.info("iteration %d starting (cost so far: $%.4f)", iteration, budget.total_cost_usd)
            cl_result = runner.invoke_claude(
                prompt=prompt,
                cwd=wt.path,
                model=config.model,
                allowed_tools=config.allowed_tools,
                disallowed_tools=config.disallowed_tools,
                permission_mode=config.permission_mode,
                bare=config.bare_mode,
                timeout_s=config.iteration_timeout_s,
                extra_args=config.extra_claude_args,
                dry_run=config.dry_run,
            )

            commit_msg = f"ralph(iter {iteration}): {(cl_result.text or '').splitlines()[0][:60] if cl_result.text else 'no output'}"
            # Claude under --permission-mode acceptEdits sometimes commits on
            # its own. Our commit_in_worktree then sees a clean tree and
            # returns None — but HEAD has moved. Use "HEAD moved" as the
            # ground-truth progress signal, regardless of who did the commit.
            our_commit_sha = worktree.commit_in_worktree(wt, commit_msg) if config.use_worktree else None
            current_sha = worktree.head_sha(wt) if config.use_worktree else ""
            head_moved = config.use_worktree and current_sha != base_sha
            files_changed = worktree.files_changed_since(wt, base_sha) if head_moved else 0
            commit_sha = our_commit_sha or (current_sha if head_moved else None)

            outcome = IterationOutcome(
                iteration=iteration,
                cost_usd=cl_result.cost_usd,
                duration_s=cl_result.duration_s,
                files_changed=files_changed,
                is_error=cl_result.is_error,
                summary=cl_result.text[:200] if cl_result.text else "",
            )
            budget.record(outcome)
            state.append_transcript(
                {
                    "iteration": iteration,
                    "cost_usd": cl_result.cost_usd,
                    "duration_s": cl_result.duration_s,
                    "return_code": cl_result.return_code,
                    "files_changed": outcome.files_changed,
                    "commit_sha": commit_sha,
                    "summary": outcome.summary,
                    "stderr": cl_result.stderr[-500:] if cl_result.stderr else "",
                }
            )

            if exit_detect.is_complete(cl_result.text or "", config.completion_signal):
                final_message = f"completion signal detected at iteration {iteration}"
                log.info(final_message)
                return _make_result(RunStatus.COMPLETE, budget, wt, config, final_message)

            base_sha = current_sha or base_sha

    except KeyboardInterrupt:
        final_message = "interrupted by user"
        return _make_result(RunStatus.INTERRUPTED, budget, wt, config, final_message)
    except Exception as exc:  # noqa: BLE001
        log.exception("loop crashed")
        return _make_result(RunStatus.FAILED, budget, wt, config, f"crash: {exc}")


def _make_result(status: RunStatus, budget: Budget, wt: worktree.Worktree, config: RunConfig, msg: str) -> RunResult:
    return RunResult(
        status=status,
        iterations=budget.iterations_completed,
        total_cost_usd=budget.total_cost_usd,
        branch=wt.branch,
        worktree_path=str(wt.path),
        output_dir=str(config.resolved_output_dir),
        final_message=msg,
    )


def _status_from_reason(reason: BlockReason) -> RunStatus:
    return {
        BlockReason.ITERATIONS_EXHAUSTED: RunStatus.ITERATIONS_EXHAUSTED,
        BlockReason.COST_EXHAUSTED: RunStatus.COST_EXHAUSTED,
        BlockReason.NO_OP_STREAK: RunStatus.NO_OP_STREAK,
        BlockReason.ERROR_STREAK: RunStatus.ERROR_STREAK,
    }.get(reason, RunStatus.FAILED)
