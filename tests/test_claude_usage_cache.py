"""Behavior tests for the Claude status-line usage cache writer."""

from __future__ import annotations

import json
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from gradus.providers import ClaudeHttpProvider

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "cache-claude-usage.py"


class ClaudeUsageCacheScriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self.output = Path(self._tmpdir.name) / "nested" / "usage.json"

    def tearDown(self) -> None:
        self._tmpdir.cleanup()

    def _run(self, payload: str, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--output", str(self.output), *extra],
            input=payload,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_writes_only_normalized_rate_limits_atomically(self) -> None:
        result = self._run(
            json.dumps(
                {
                    "session_id": "must-not-persist",
                    "rate_limits": {
                        "five_hour": {"used_percentage": 1, "resets_at": 1_800_000_000},
                        "seven_day": {"used_percentage": 81.25, "resets_at": 1_900_000_000},
                    },
                }
            )
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        cached = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(set(cached), {"schema_version", "observed_at", "five_hour", "seven_day"})
        self.assertEqual(cached["five_hour"]["used_percentage"], 1.0)
        self.assertNotIn("session_id", cached)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.output.parent.stat().st_mode), 0o700)
        self.assertEqual(list(self.output.parent.glob("*.tmp")), [])

    def test_missing_rate_limits_preserves_existing_cache(self) -> None:
        self.output.parent.mkdir(parents=True)
        self.output.write_text("existing", encoding="utf-8")
        result = self._run("{}")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "existing")

    def test_invalid_json_fails_without_partial_output(self) -> None:
        result = self._run("{")
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.output.exists())

    def test_invalid_bucket_fails_without_replacing_existing_cache(self) -> None:
        self.output.parent.mkdir(parents=True)
        self.output.write_text("existing", encoding="utf-8")
        result = self._run(json.dumps({"rate_limits": {"five_hour": {"used_percentage": 101}}}))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "existing")
        self.assertEqual(list(self.output.parent.glob("*.tmp")), [])

    def test_unknown_argument_fails_without_output(self) -> None:
        result = self._run("{}", "--unknown")
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.output.exists())

    def test_status_line_json_roundtrips_into_provider_without_http(self) -> None:
        result = self._run(
            json.dumps(
                {
                    "rate_limits": {
                        "five_hour": {"used_percentage": 1, "resets_at": 1_800_000_000},
                        "seven_day": {"used_percentage": 81, "resets_at": 1_900_000_000},
                    }
                }
            )
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        with (
            patch.object(ClaudeHttpProvider, "_STATUS_CACHE_PATH", self.output),
            patch("gradus.providers._base._http_json") as http_json,
        ):
            status = ClaudeHttpProvider().fetch()
        self.assertEqual(status.session_percent_left, 99)
        self.assertEqual(status.weekly_percent_left, 19)
        self.assertIsNotNone(status.primary_reset)
        self.assertIsNotNone(status.secondary_reset)
        http_json.assert_not_called()


if __name__ == "__main__":
    unittest.main()
