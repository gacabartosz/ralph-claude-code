"""CLI: `ralph version` and `ralph init`."""
from __future__ import annotations

from pathlib import Path

from typer.testing import CliRunner

from ralph import __version__
from ralph.cli import app


def test_version_command():
    runner = CliRunner()
    result = runner.invoke(app, ["version"])
    assert result.exit_code == 0
    assert __version__ in result.output


def test_init_writes_prompt_md(tmp_path: Path):
    runner = CliRunner()
    out = tmp_path / "PROMPT.md"
    result = runner.invoke(app, ["init", "--out", str(out), "--mission", "Test mission"])
    assert result.exit_code == 0
    assert out.exists()
    text = out.read_text(encoding="utf-8")
    assert "Test mission" in text
    assert "EXIT_SIGNAL: true" in text
    assert "fix_plan.md" in text


def test_init_refuses_overwrite_without_flag(tmp_path: Path):
    runner = CliRunner()
    out = tmp_path / "PROMPT.md"
    out.write_text("existing", encoding="utf-8")
    result = runner.invoke(app, ["init", "--out", str(out)])
    assert result.exit_code == 1
    assert "already exists" in result.output
    assert out.read_text(encoding="utf-8") == "existing"


def test_init_overwrite_flag_replaces(tmp_path: Path):
    runner = CliRunner()
    out = tmp_path / "PROMPT.md"
    out.write_text("existing", encoding="utf-8")
    result = runner.invoke(app, ["init", "--out", str(out), "--overwrite"])
    assert result.exit_code == 0
    assert "Mission" in out.read_text(encoding="utf-8")


def test_init_custom_completion_signal(tmp_path: Path):
    runner = CliRunner()
    out = tmp_path / "PROMPT.md"
    result = runner.invoke(
        app,
        ["init", "--out", str(out), "--completion-signal", "DONE_SIGNAL: 42"],
    )
    assert result.exit_code == 0
    assert "DONE_SIGNAL: 42" in out.read_text(encoding="utf-8")
