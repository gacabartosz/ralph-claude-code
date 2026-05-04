"""Parse ISSUES.md from a Ralph audit run and file them as GitHub issues.

Usage:
    uv run python scripts/file_issues.py \\
        --issues-md /path/to/ISSUES.md \\
        --repo gacabartosz/mcp-zus \\
        [--dry-run] [--severity P0,P1]

ISSUES.md format expected (per Ralph audit-mcp prompts):

    ## P1 — partial but advertised as done

    ### P1-001 — Short title

    **Title:** ...
    **Labels:** bug, docs
    **Severity:** P1
    **Reproduction:** ...
    **Suggested fix / next step:** ...

    ---

    ### P1-002 — ...

We split on `### ` headings inside `## Pn` sections, then call `gh issue create`
for each block. By default we only file P0/P1 unless `--severity` overrides.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(slots=True)
class IssueDraft:
    code: str  # e.g. P1-001
    title: str
    severity: str
    labels: list[str]
    body: str


def parse_issues_md(text: str) -> list[IssueDraft]:
    """Extract individual issue blocks from a ISSUES.md."""
    drafts: list[IssueDraft] = []

    # Split into severity sections.
    sections = re.split(r"(?m)^## (P[0-3])\b[^\n]*\n", text)
    # sections = ['<preamble>', 'P0', '<P0 body>', 'P1', '<P1 body>', ...]
    for i in range(1, len(sections), 2):
        sev = sections[i]
        body = sections[i + 1] if i + 1 < len(sections) else ""

        # Skip empty placeholder sections like "(none recorded yet)".
        if "_(none" in body.lower() or not body.strip():
            continue

        # Each issue starts with `### Pn-NNN — Title`.
        items = re.split(r"(?m)^### (P[0-3]-\d+)\s*—\s*([^\n]+)\n", body)
        for j in range(1, len(items), 3):
            code = items[j].strip()
            heading_title = items[j + 1].strip()
            block = items[j + 2] if j + 2 < len(items) else ""

            # Stop at next `### `, `## `, or section divider `---`.
            block = re.split(r"(?m)^(?:---\s*$|## |### )", block, maxsplit=1)[0].strip()

            # Pull explicit Title field if present, else use heading.
            m = re.search(r"(?m)^\*\*Title:\*\*\s*(.+)$", block)
            title = m.group(1).strip() if m else heading_title

            # Pull labels.
            ml = re.search(r"(?m)^\*\*Labels:\*\*\s*(.+)$", block)
            labels = []
            if ml:
                labels = [s.strip() for s in re.split(r"[,\|]", ml.group(1)) if s.strip()]

            drafts.append(
                IssueDraft(
                    code=code,
                    title=f"[{code}] {title}",
                    severity=sev,
                    labels=labels,
                    body=block,
                )
            )

    return drafts


def file_issue(repo: str, draft: IssueDraft, *, dry_run: bool) -> None:
    cmd = ["gh", "issue", "create", "--repo", repo, "--title", draft.title]
    for label in draft.labels:
        cmd += ["--label", label]
    cmd += ["--body", draft.body]
    if dry_run:
        print(f"[DRY] would file: {draft.title}")
        print(f"      labels: {draft.labels}")
        print(f"      body length: {len(draft.body)} chars")
        return

    print(f"Filing: {draft.title}")
    res = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if res.returncode != 0:
        print(f"  FAILED: {res.stderr.strip()}", file=sys.stderr)
    else:
        print(f"  → {res.stdout.strip()}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--issues-md", required=True, type=Path, help="Path to ISSUES.md from a Ralph audit run")
    ap.add_argument("--repo", required=True, help="GitHub repo (owner/name)")
    ap.add_argument("--severity", default="P0,P1", help="Comma-separated severities to file (default P0,P1)")
    ap.add_argument("--dry-run", action="store_true", help="Don't actually call gh issue create")
    args = ap.parse_args()

    text = args.issues_md.read_text(encoding="utf-8")
    drafts = parse_issues_md(text)
    keep = {s.strip() for s in args.severity.split(",")}
    drafts = [d for d in drafts if d.severity in keep]

    print(f"Found {len(drafts)} issues at severity {sorted(keep)}")
    for d in drafts:
        file_issue(args.repo, d, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
