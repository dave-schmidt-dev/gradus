"""Repository hygiene checks for HISTORY.md invariant tags."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUG_ENTRY = re.compile(r"^\s*[-*]\s+\[bug\]")
LIST_ITEM = re.compile(r"^\s*[-*]\s+")
HEADING = re.compile(r"^\s*#")
INV_TAG = re.compile(r"\|\s*inv:\s*(?:INV-[\w.-]+|NA)(?=\s|,|$)")


def _bug_entries() -> list[tuple[int, str]]:
    lines = (ROOT / "HISTORY.md").read_text().splitlines()
    entries: list[tuple[int, str]] = []
    index = 0
    while index < len(lines):
        if not BUG_ENTRY.match(lines[index]):
            index += 1
            continue

        start_line = index + 1
        block = [lines[index]]
        index += 1
        while index < len(lines):
            line = lines[index]
            if not line.strip() or LIST_ITEM.match(line) or HEADING.match(line):
                break
            block.append(line)
            index += 1
        entries.append((start_line, " ".join(part.strip() for part in block)))
    return entries


def test_every_bug_history_entry_has_an_invariant_tag() -> None:
    missing = [line_number for line_number, entry in _bug_entries() if not INV_TAG.search(entry)]
    assert not missing, f"[bug] entries missing inv: tag at HISTORY.md lines {missing}"
