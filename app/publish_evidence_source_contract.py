#!/usr/bin/env python3
"""Check the diagnostics-aware producer-evidence contract in PublishCoordinator."""

from __future__ import annotations

import re
import sys
from pathlib import Path


class SourceContractError(ValueError):
    """The coordinator no longer satisfies the upload evidence contract."""


def _section(source: str, start: str, end: str, label: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise SourceContractError(f"{label} method boundary is missing or ambiguous")
    start_at = source.find(start)
    end_at = source.find(end, start_at + len(start))
    if end_at < 0:
        raise SourceContractError(f"{label} method boundary is out of order")
    return source[start_at:end_at]


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise SourceContractError(message)


def validate_source_contract(source: str) -> None:
    """Validate publish ordering, diagnostics propagation, and timestamp creation."""
    publish = _section(
        source,
        "    private func publishOnce(",
        "    private func diffAgainstState(",
        "publishOnce",
    )
    wrapper_call = "try await writeProducerEvidenceWithDiagnostics()"
    _require(
        publish.count(wrapper_call) == 2,
        "quiet and changed publish paths must refresh producer evidence",
    )
    _require(
        "writeProducerEvidenceIfConfigured(" not in publish,
        "publishOnce must use the diagnostics wrapper",
    )

    quiet_marker = "guard !toSave.isEmpty else {"
    _require(publish.count(quiet_marker) == 1, "quiet publish branch is missing or ambiguous")
    quiet_start = publish.index(quiet_marker)
    quiet_close = publish.find("\n        }", quiet_start)
    quiet_return = publish.find("\n            return", quiet_start)
    _require(
        quiet_close >= 0 and quiet_return >= 0 and quiet_return < quiet_close,
        "quiet publish branch must return from its guard body",
    )
    quiet = publish[quiet_start:quiet_close]
    quiet_call = quiet.find(wrapper_call)
    _require(
        quiet.count(wrapper_call) == 1 and 0 <= quiet_call < quiet_return - quiet_start,
        "quiet publish path must refresh evidence before returning",
    )

    calls = [match.start() for match in re.finditer(re.escape(wrapper_call), publish)]
    failure = re.search(
        r"\n        if failedRecordCount > 0 \{.*?\n        \}",
        publish,
        re.DOTALL,
    )
    _require(failure is not None, "changed publish failure handling is missing")
    failure_text = failure.group(0)
    _require(
        "throw PublishCoordinatorError.recordFailures(failedRecordCount)" in failure_text,
        "failed record saves must still throw before evidence success",
    )
    changed_call = calls[1]
    success_notice = 'GradusLog.publish.notice("published '
    _require(
        publish.count(success_notice) == 1, "changed publish success notice is missing or ambiguous"
    )
    _require(
        failure.end() < changed_call < publish.index(success_notice),
        "changed-path evidence must follow failure handling and precede success notice",
    )

    wrapper = _section(
        source,
        "    private func writeProducerEvidenceWithDiagnostics() async throws {",
        "    private func writeProducerEvidenceIfConfigured() throws {",
        "diagnostics wrapper",
    )
    wrapper_pattern = re.compile(
        r"do\s*\{\s*try\s+writeProducerEvidenceIfConfigured\(\)\s*\}"
        r"\s*catch\s*\{\s*await diagnostics\.artifactFailure\(error\)"
        r"\s*throw error\s*\}"
    )
    _require(
        wrapper.count("writeProducerEvidenceIfConfigured(") == 1
        and wrapper_pattern.search(wrapper) is not None,
        "diagnostics wrapper must delegate once, report failure, and rethrow it",
    )

    conditional = _section(
        source,
        "    private func writeProducerEvidenceIfConfigured() throws {",
        "    private static func writeProducerEvidence(",
        "conditional evidence writer",
    )
    _require(
        conditional.count("Self.writeProducerEvidence(") == 1
        and source.count("Self.writeProducerEvidence(") == 1,
        "conditional writer must call the sole static evidence writer",
    )

    static_writer = _section(
        source,
        "    private static func writeProducerEvidence(",
        "    private func retryServerRecordChanged(",
        "static evidence writer",
    )
    _require(
        static_writer.count("publishedAt: Date()") == 1,
        "static evidence writer must stamp evidence with the current Date",
    )


def main() -> int:
    source_path = Path(__file__).resolve().parent / "GradusMac" / "PublishCoordinator.swift"
    try:
        validate_source_contract(source_path.read_text(encoding="utf-8"))
    except (OSError, SourceContractError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PublishCoordinator producer evidence source contract passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
