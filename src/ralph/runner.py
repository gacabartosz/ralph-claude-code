"""Subprocess wrapper around `claude -p --output-format json`.

Each `invoke_claude()` call = one iteration of Ralph.
"""
from __future__ import annotations

import json
import logging
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger(__name__)


class RunnerError(RuntimeError):
    pass


@dataclass(slots=True)
class ClaudeResult:
    """Parsed result of one `claude -p` invocation."""

    success: bool
    text: str  # primary assistant output (concatenated)
    cost_usd: float
    duration_s: float
    raw_json: dict | None
    stderr: str
    return_code: int

    @property
    def is_error(self) -> bool:
        return not self.success or self.return_code != 0


def invoke_claude(
    *,
    prompt: str,
    cwd: Path,
    model: str,
    allowed_tools: list[str],
    disallowed_tools: list[str] | None = None,
    permission_mode: str = "acceptEdits",
    bare: bool = True,
    timeout_s: int = 600,
    extra_args: list[str] | None = None,
    dry_run: bool = False,
) -> ClaudeResult:
    """Invoke `claude -p` once, capture output, parse JSON, return structured result.

    The prompt is passed via stdin (Huntley's canonical `cat PROMPT.md | claude` form).
    """
    if dry_run:
        return _dry_run_stub(prompt)

    cmd = ["claude", "-p", "--output-format", "json", "--no-session-persistence"]
    if bare:
        cmd.append("--bare")
    cmd += ["--model", model]
    cmd += ["--permission-mode", permission_mode]
    if allowed_tools:
        cmd += ["--allowedTools", *allowed_tools]
    if disallowed_tools:
        cmd += ["--disallowedTools", *disallowed_tools]
    if extra_args:
        cmd += extra_args

    start = time.monotonic()
    try:
        proc = subprocess.run(
            cmd,
            input=prompt,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=timeout_s,
            check=False,
        )
    except subprocess.TimeoutExpired as e:
        duration = time.monotonic() - start
        log.warning("claude -p timed out after %.1fs", duration)
        return ClaudeResult(
            success=False,
            text=(e.stdout or ""),
            cost_usd=0.0,
            duration_s=duration,
            raw_json=None,
            stderr=f"timeout after {timeout_s}s",
            return_code=124,
        )
    except FileNotFoundError as e:
        raise RunnerError("claude CLI not found on PATH; install Claude Code first") from e

    duration = time.monotonic() - start

    raw_json: dict | None = None
    text = proc.stdout or ""
    cost_usd = 0.0

    if text.strip():
        try:
            raw_json = json.loads(text)
            text = raw_json.get("result") or raw_json.get("response") or ""
            cost_usd = float(raw_json.get("total_cost_usd", 0.0) or 0.0)
        except json.JSONDecodeError:
            log.debug("claude output was not JSON; treating as plain text")

    return ClaudeResult(
        success=proc.returncode == 0,
        text=text,
        cost_usd=cost_usd,
        duration_s=duration,
        raw_json=raw_json,
        stderr=proc.stderr or "",
        return_code=proc.returncode,
    )


def _dry_run_stub(prompt: str) -> ClaudeResult:
    """Fake claude response for `--dry-run` — used in tests + CLI smoke."""
    return ClaudeResult(
        success=True,
        text=f"[dry-run] would have processed prompt of {len(prompt)} chars",
        cost_usd=0.0,
        duration_s=0.01,
        raw_json={"result": "dry-run", "total_cost_usd": 0.0},
        stderr="",
        return_code=0,
    )
