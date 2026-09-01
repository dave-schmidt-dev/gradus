"""Pin the legacy-runtime facts the Swift cutover reads against their sources.

`LegacyRuntimeMigrator` is covered end to end by fakes, and a fake agrees with
whatever the adapter believes.  So a wrong key name or a renamed wrapper stays
green through every Swift test and only fails during a live cutover -- where
the symptom is a rollback with no visible cause, because "I could not read a
fresh snapshot" and "there was no fresh snapshot" look identical from Settings.

Four of these were real, found by reading this machine's own files on
2026-09-01 rather than by any test:

* the snapshot's timestamp is ``updated_at``, not ``updatedAt``
* ``publish-evidence.json`` carries no ``ok`` field at all
* ``launchctl print-disabled`` prints ``=> disabled``, not ``=> true``
* the standalone bridge lives in ``~/Applications``, not ``/Applications``

Text-level like ``test_swift_carry_marker_parity.py``: these run in the Python
gate in seconds instead of waiting on a Mac test host.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from gradus.history import _ALLOWED_SNAPSHOT_KEYS
from gradus.paths import installed_runtime_paths

ROOT = Path(__file__).resolve().parents[1]
HOSTS = ROOT / "app" / "GradusMac" / "LegacyRuntimeMigrationHosts.swift"
INSTALL = ROOT / "launchd" / "install.sh"
WRAPPER_TEMPLATE = ROOT / "launchd" / "gradus_snapshot.sh.in"


class LegacyAdapterParityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.hosts = HOSTS.read_text()
        self.install = INSTALL.read_text()

    def test_the_snapshot_timestamp_key_is_one_the_producer_writes(self) -> None:
        self.assertIn("updated_at", _ALLOWED_SNAPSHOT_KEYS)
        self.assertIn(
            '"updated_at"',
            self.hosts,
            "the cutover waits on `snapshotUpdatedAt()`; reading a key the Python "
            "producer never writes rolls every migration back as `.noFreshSnapshots`",
        )

    def test_no_snapshot_key_is_read_that_the_producer_cannot_write(self) -> None:
        # `updatedAt` is deliberately accepted as a fallback, so the rule is
        # only that the snake_case spelling appears -- checked above -- and that
        # nothing else invented shows up beside it.
        for invented in ('"lastUpdated"', '"timestamp"', '"refreshedAt"'):
            self.assertNotIn(invented, self.hosts)

    def test_publish_evidence_success_is_not_gated_on_an_absent_field(self) -> None:
        # The publisher writes cloudKitEnvironment/producerBuildNumber/
        # projectSha256/publishedAt/sourceRevision. Requiring `ok == true` made
        # `verifyingPublish` unreachable on every real machine.
        self.assertIn('object["ok"] as? Bool, !ok', self.hosts)
        self.assertNotIn('object["ok"] as? Bool == true', self.hosts)

    def test_the_legacy_label_matches_the_installer(self) -> None:
        self.assertIn('readonly LABEL="local.gradus-snapshot"', self.install)
        self.assertIn('legacyLabel = "local.gradus-snapshot"', self.hosts)

    def test_the_legacy_wrapper_path_matches_the_installer(self) -> None:
        self.assertIn('"$INSTALL_HOME/.launchd/scripts/gradus_snapshot.sh"', self.install)
        self.assertIn('".launchd/scripts/gradus_snapshot.sh"', self.hosts)

    def test_the_producer_pattern_matches_what_the_wrapper_actually_runs(self) -> None:
        wrapper = WRAPPER_TEMPLATE.read_text()
        self.assertIn('"${GRADUS_PYTHON}" -m gradus --refresh-snapshot', wrapper)
        self.assertIn(
            'legacyProducerPattern = "-m gradus --refresh-snapshot"',
            self.hosts,
            "the wrapper spawns the producer rather than exec-ing it, so a "
            "wrapper-only pgrep reports the legacy runtime stopped while an "
            "orphaned producer is still writing snapshots",
        )

    def test_the_dash_leading_pattern_is_passed_after_an_end_of_options_marker(self) -> None:
        # `pgrep -f "-m gradus ..."` exits 2 with `illegal option -- m`.
        self.assertIn('["-f", "--", pattern]', self.hosts)

    def test_print_disabled_is_parsed_in_the_shape_launchctl_prints(self) -> None:
        self.assertIn('value == "disabled"', self.hosts)
        self.assertNotIn('=> true")', self.hosts)

    def test_the_standalone_bridge_is_looked_for_in_the_users_applications(self) -> None:
        self.assertIn('"Applications/GradusCredentialBridge.app"', self.hosts)

    def test_the_preflight_creates_every_directory_the_producer_needs(self) -> None:
        # The producer creates the leaf of each with a bare `mkdir` so its lock
        # cannot be reached through a symlinked parent, which means an isolated
        # `HOME` without these fails with ENOENT and exits 1 before probing.
        home = Path("/tmp/isolated")
        paths = installed_runtime_paths(
            application_support_root=home / "Library" / "Application Support" / "Gradus",
            logs_root=home / "Library" / "Logs" / "Gradus",
        )
        required = {
            str(paths.public_state_root.relative_to(home)),
            str(paths.private_cache_root.relative_to(home)),
            str(paths.log_root.relative_to(home)),
        }
        for directory in required:
            self.assertIn(
                f'"{directory}"',
                self.hosts,
                "BundledProducerPreflight.producerStateDirectories is missing a "
                "directory the installed-mode producer needs; without it the "
                "preflight can never pass and `migrate()` is unreachable",
            )


if __name__ == "__main__":
    unittest.main()
