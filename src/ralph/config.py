"""Run configuration for a Ralph loop."""
from __future__ import annotations

from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field

DEFAULT_ALLOWED_TOOLS = [
    "Read",
    "Edit",
    "Write",
    "Glob",
    "Grep",
    "Bash(uv *)",
    "Bash(python *)",
    "Bash(pytest*)",
    "Bash(git status*)",
    "Bash(git diff*)",
    "Bash(git log*)",
    "Bash(ls *)",
    "Bash(cat *)",
    "Bash(head *)",
    "Bash(tail *)",
]


class RunConfig(BaseModel):
    """All knobs for one Ralph run."""

    # Identity
    run_id: str
    repo_path: Path
    prompt_path: Path

    # Loop budget (hard caps)
    max_iterations: int = Field(default=30, ge=1, le=500)
    max_cost_usd: float = Field(default=20.0, gt=0, le=1000.0)
    iteration_timeout_s: int = Field(default=600, ge=10, le=3600)

    # Circuit breaker
    circuit_breaker_enabled: bool = True
    no_op_streak_threshold: int = 3  # 3 iters w/o file change → break
    error_streak_threshold: int = 5  # 5 error iters → break

    # Claude CLI invocation
    model: str = "claude-opus-4-7"
    allowed_tools: list[str] = Field(default_factory=lambda: DEFAULT_ALLOWED_TOOLS.copy())
    # `claude -p --bare` skips keychain auth (requires ANTHROPIC_API_KEY env var).
    # Default False so users with `claude auth login` keychain creds just work.
    bare_mode: bool = False
    permission_mode: Literal["acceptEdits", "auto", "default", "plan", "bypassPermissions"] = "acceptEdits"
    extra_claude_args: list[str] = Field(default_factory=list)

    # Worktree
    use_worktree: bool = True
    worktree_root: Path | None = None  # default: <repo>/.ralph-worktrees/
    keep_worktree_on_success: bool = False
    branch_name: str | None = None  # default: ralph/<run-id>

    # Output
    output_root: Path | None = None  # default: <repo>/.ralph-runs/
    completion_signal: str = "EXIT_SIGNAL: true"

    # Safety
    dry_run: bool = False  # don't actually call claude — return stub responses

    # MCP audit mode (ignored in generic `run`)
    mcp_cmd: list[str] | None = None

    @property
    def resolved_branch(self) -> str:
        return self.branch_name or f"ralph/{self.run_id}"

    @property
    def resolved_output_dir(self) -> Path:
        root = self.output_root or (self.repo_path / ".ralph-runs")
        return root / self.run_id

    @property
    def resolved_worktree_root(self) -> Path:
        return self.worktree_root or (self.repo_path / ".ralph-worktrees")
