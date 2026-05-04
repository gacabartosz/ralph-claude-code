"""scripts/file_issues.py — markdown parser for ISSUES.md."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[2] / "scripts"))

from file_issues import parse_issues_md  # noqa: E402

SAMPLE = """# ISSUES.md

Group by severity.

## P0 — broken / misleading

_(none recorded yet)_

## P1 — partial but advertised as done

### P1-001 — kedu.* tools have empty descriptions

**Title:** kedu.* — every tool exposes empty `description`

**Labels:** bug, docs, mcp-protocol

**Severity:** P1

**Reproduction:**
1. Send tools/list.

**Expected:** non-empty description.

**Actual:** empty.

---

### P1-002 — okwud.* same defect

**Title:** okwud.* tools also empty

**Labels:** bug

**Severity:** P1

**Reproduction:**
1. Same flow.

---

## P2 — WIP gaps to track

_(none recorded yet)_

## P3 — cleanup / docs

_(none)_
"""


def test_parses_two_p1_issues():
    drafts = parse_issues_md(SAMPLE)
    assert len(drafts) == 2
    codes = [d.code for d in drafts]
    assert codes == ["P1-001", "P1-002"]


def test_extracts_explicit_title():
    drafts = parse_issues_md(SAMPLE)
    assert drafts[0].title == "[P1-001] kedu.* — every tool exposes empty `description`"


def test_extracts_labels():
    drafts = parse_issues_md(SAMPLE)
    assert "bug" in drafts[0].labels
    assert "docs" in drafts[0].labels
    assert "mcp-protocol" in drafts[0].labels


def test_skips_empty_placeholder_sections():
    drafts = parse_issues_md(SAMPLE)
    # P0/P2/P3 are all "_(none recorded yet)_" → skipped
    assert all(d.severity == "P1" for d in drafts)


def test_body_includes_reproduction():
    drafts = parse_issues_md(SAMPLE)
    assert "Reproduction" in drafts[0].body
    assert "Send tools/list" in drafts[0].body


def test_body_does_not_leak_into_next_issue():
    drafts = parse_issues_md(SAMPLE)
    # P1-001's body should NOT contain P1-002's title.
    assert "okwud.* tools also empty" not in drafts[0].body
    assert "kedu.* tools have empty" not in drafts[1].body
