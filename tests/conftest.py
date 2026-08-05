"""Suite-wide test isolation.

Keeps the test run from writing into the production log. Before this existed,
`_setup_logging` wrote to a single hard-coded `/tmp/gradus.log` that the suite
shared with the live TUI and the launchd snapshot job. A full run emitted
thousands of WARNING lines (largely `refusing snapshot write with invalid
updated_at`, from snapshots built against pytest tmp dirs), which pushed the
1 MB rotation and discarded real production evidence -- observed during this
work: the log rotated from 983874 bytes down to 79051 mid-session.
"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

# Set at import, before any test can call `_setup_logging`. `gradus.__main__`
# reads this via `_resolve_log_path()` on every call rather than binding it at
# module import, so setting it here is sufficient and does not depend on
# import order between conftest and the module under test.
_TEST_LOG_DIR = Path(tempfile.gettempdir()) / "gradus-pytest-logs"
_TEST_LOG_DIR.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("GRADUS_LOG_PATH", str(_TEST_LOG_DIR / "gradus-test.log"))
