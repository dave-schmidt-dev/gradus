"""Antigravity private token-file fallback tests."""

from __future__ import annotations

import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from gradus.providers import AntigravityProvider, ProbeFailure
from gradus.providers.antigravity import AUTH_SIGN_IN_ERROR


class AntigravityTokenFileTests(unittest.TestCase):
    SUMMARY_RESPONSE = {
        "groups": [
            {
                "displayName": "Gemini Models",
                "buckets": [
                    {
                        "bucketId": "gemini-weekly",
                        "window": "weekly",
                        "resetTime": "2026-07-11T20:52:22Z",
                        "remainingFraction": 0.95879453,
                    },
                    {
                        "bucketId": "gemini-5h",
                        "window": "5h",
                        "resetTime": "2026-07-06T05:31:46Z",
                        "remainingFraction": 0.8624946,
                    },
                ],
            },
        ],
    }

    def setUp(self) -> None:
        self._token_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._token_dir.cleanup)
        self._token_path = Path(self._token_dir.name) / "antigravity-oauth-token"
        self._token_path_patch = patch.object(
            AntigravityProvider,
            "_TOKEN_FILE_PATH",
            self._token_path,
        )
        self._token_path_patch.start()
        self.addCleanup(self._token_path_patch.stop)

    def _token(
        self,
        *,
        access_token: str = "ya29.file-token",
        expiry: str = "2999-01-01T00:00:00+00:00",
    ) -> dict:
        return {
            "access_token": access_token,
            "refresh_token": "1//agy-refresh",
            "token_type": "Bearer",
            "expiry": expiry,
        }

    def _write_token_file(
        self,
        token: dict,
        *,
        mode: int = 0o600,
        path: Path | None = None,
    ) -> Path:
        target = path or self._token_path
        payload = {
            "auth_method": "consumer",
            "id_token_email": "user@example.com",
            "token": token,
        }
        target.write_bytes(json.dumps(payload).encode("utf-8"))
        target.chmod(mode)
        return target

    def test_missing_keychain_uses_file_token_bearer(self) -> None:
        file_token = self._token(access_token="ya29.from-file")
        self._write_token_file(file_token)
        provider = AntigravityProvider()
        with (
            patch.object(
                AntigravityProvider,
                "_load_keychain_token",
                side_effect=FileNotFoundError("missing"),
            ),
            patch(
                "gradus.providers._base._http_json", return_value=self.SUMMARY_RESPONSE
            ) as mock_http,
        ):
            status = provider.fetch()
        self.assertAlmostEqual(status.five_hour_percent_left, 86.24946, places=5)
        _, kwargs = mock_http.call_args
        self.assertEqual(kwargs["headers"]["Authorization"], "Bearer ya29.from-file")

    def test_expired_keychain_prefers_fresh_file_without_nudge(self) -> None:
        expired = self._token(access_token="ya29.keychain", expiry="2000-01-01T00:00:00+00:00")
        fresh = self._token(access_token="ya29.from-file")
        self._write_token_file(fresh)
        provider = AntigravityProvider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=expired),
            patch("gradus.providers.subprocess.run") as mock_run,
            patch(
                "gradus.providers._base._http_json", return_value=self.SUMMARY_RESPONSE
            ) as mock_http,
        ):
            status = provider.fetch()
        self.assertAlmostEqual(status.weekly_percent_left, 95.879453, places=6)
        mock_run.assert_not_called()
        _, kwargs = mock_http.call_args
        self.assertEqual(kwargs["headers"]["Authorization"], "Bearer ya29.from-file")

    def test_fresh_keychain_does_not_open_file(self) -> None:
        keychain = self._token(access_token="ya29.keychain")
        self._write_token_file(self._token(access_token="ya29.from-file"))
        provider = AntigravityProvider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=keychain),
            patch.object(
                AntigravityProvider, "_load_file_token", wraps=AntigravityProvider._load_file_token
            ) as mock_file,
            patch(
                "gradus.providers._base._http_json", return_value=self.SUMMARY_RESPONSE
            ) as mock_http,
        ):
            status = provider.fetch()
        self.assertAlmostEqual(status.five_hour_percent_left, 86.24946, places=5)
        mock_file.assert_not_called()
        _, kwargs = mock_http.call_args
        self.assertEqual(kwargs["headers"]["Authorization"], "Bearer ya29.keychain")

    def test_missing_keychain_expired_file_nudges_and_accepts_refresh(self) -> None:
        expired = self._token(access_token="ya29.stale-file", expiry="2000-01-01T00:00:00+00:00")
        fresh = self._token(access_token="ya29.refreshed-file")
        self._write_token_file(expired)

        def _after_nudge(*args, **kwargs):
            self._write_token_file(fresh)
            return MagicMock(returncode=0)

        provider = AntigravityProvider()
        with (
            patch.object(
                AntigravityProvider,
                "_load_keychain_token",
                side_effect=FileNotFoundError("missing"),
            ),
            patch("gradus.providers.antigravity.shutil.which", return_value="agy"),
            patch(
                "gradus.providers.subprocess.run",
                side_effect=_after_nudge,
            ) as mock_run,
            patch(
                "gradus.providers._base._http_json", return_value=self.SUMMARY_RESPONSE
            ) as mock_http,
        ):
            status = provider.fetch()
        self.assertAlmostEqual(status.five_hour_percent_left, 86.24946, places=5)
        mock_run.assert_called_once()
        self.assertEqual(list(mock_run.call_args[0][0]), ["agy", "models"])
        _, kwargs = mock_http.call_args
        self.assertEqual(kwargs["headers"]["Authorization"], "Bearer ya29.refreshed-file")

    def test_both_missing_raises_sign_in_error_without_nudge(self) -> None:
        provider = AntigravityProvider()
        with (
            patch.object(
                AntigravityProvider,
                "_load_keychain_token",
                side_effect=FileNotFoundError("missing"),
            ),
            patch.object(AntigravityProvider, "_trigger_agy_self_refresh") as mock_nudge,
            patch("gradus.providers.subprocess.run") as mock_run,
            patch("gradus.providers._base._http_json") as mock_http,
        ):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertEqual(str(ctx.exception), AUTH_SIGN_IN_ERROR)
        mock_nudge.assert_not_called()
        mock_run.assert_not_called()
        mock_http.assert_not_called()

    def test_load_file_token_rejects_symlink(self) -> None:
        real = Path(self._token_dir.name) / "real-token"
        self._write_token_file(self._token(), path=real)
        self._token_path.symlink_to(real)
        self.assertEqual(AntigravityProvider._load_file_token(), {})

    def test_load_file_token_rejects_group_readable(self) -> None:
        self._write_token_file(self._token(), mode=0o644)
        self.assertEqual(AntigravityProvider._load_file_token(), {})

    def test_load_file_token_rejects_oversize(self) -> None:
        self._token_path.write_bytes(b"x" * (AntigravityProvider._TOKEN_FILE_MAX_BYTES + 1))
        self._token_path.chmod(0o600)
        self.assertEqual(AntigravityProvider._load_file_token(), {})

    def test_load_file_token_rejects_invalid_json(self) -> None:
        self._token_path.write_bytes(b"{not-json")
        self._token_path.chmod(0o600)
        self.assertEqual(AntigravityProvider._load_file_token(), {})

    def test_load_file_token_rejects_non_dict_token(self) -> None:
        self._token_path.write_bytes(
            json.dumps({"auth_method": "consumer", "token": "not-a-dict"}).encode()
        )
        self._token_path.chmod(0o600)
        self.assertEqual(AntigravityProvider._load_file_token(), {})

    def test_load_file_token_missing_file(self) -> None:
        self.assertFalse(self._token_path.exists())
        self.assertEqual(AntigravityProvider._load_file_token(), {})

    def test_load_file_token_leaves_bytes_and_mode_unchanged(self) -> None:
        payload = {
            "auth_method": "consumer",
            "id_token_email": "user@example.com",
            "token": self._token(),
        }
        raw = json.dumps(payload).encode("utf-8")
        self._token_path.write_bytes(raw)
        self._token_path.chmod(0o600)
        before_mode = self._token_path.stat().st_mode
        before_bytes = self._token_path.read_bytes()
        token = AntigravityProvider._load_file_token()
        self.assertEqual(token["access_token"], "ya29.file-token")
        self.assertEqual(self._token_path.read_bytes(), before_bytes)
        self.assertEqual(self._token_path.stat().st_mode, before_mode)
        self.assertEqual(stat.S_IMODE(before_mode), 0o600)
        # Prove we did not chmod as a side effect of the read path.
        self.assertEqual(os.stat(self._token_path).st_mode & 0o777, 0o600)

    def test_load_file_token_rejects_deeply_nested_json(self) -> None:
        self._token_path.write_bytes(b"[" * 60000)
        self._token_path.chmod(0o600)
        self.assertEqual(AntigravityProvider._load_file_token(), {})

    def test_load_file_token_rejects_fifo_without_blocking(self) -> None:
        os.mkfifo(self._token_path, 0o600)
        self.assertEqual(AntigravityProvider._load_file_token(), {})

    def test_load_file_token_rejects_unusable_access_token(self) -> None:
        for bad in (True, 7, "", "ya29 with space", "ya29\r\nX-Injected: 1", ["ya29"]):
            with self.subTest(access_token=bad):
                self._write_token_file({"access_token": bad, "expiry": "2999-01-01T00:00:00+00:00"})
                self.assertEqual(AntigravityProvider._load_file_token(), {})

    def test_load_file_token_keeps_only_access_token_and_expiry(self) -> None:
        self._write_token_file(self._token())
        self.assertEqual(
            AntigravityProvider._load_file_token(),
            {"access_token": "ya29.file-token", "expiry": "2999-01-01T00:00:00+00:00"},
        )

    def test_unusable_file_token_does_not_displace_expired_keychain_token(self) -> None:
        expired = self._token(access_token="ya29.keychain", expiry="2000-01-01T00:00:00+00:00")
        self._write_token_file({"access_token": True})
        with patch.object(AntigravityProvider, "_load_keychain_token", return_value=expired):
            self.assertEqual(AntigravityProvider._load_token(), expired)

    def test_unusable_keychain_token_is_never_selected(self) -> None:
        for bad in (True, "ya29\r\nX-Injected: 1"):
            with self.subTest(access_token=bad):
                keychain = {"access_token": bad, "expiry": "2999-01-01T00:00:00+00:00"}
                with patch.object(
                    AntigravityProvider, "_load_keychain_token", return_value=keychain
                ):
                    self.assertEqual(AntigravityProvider._load_token(), {})
                    self._write_token_file(self._token())
                    self.assertEqual(
                        AntigravityProvider._load_token()["access_token"], "ya29.file-token"
                    )
                os.unlink(self._token_path)


class AntigravityTokenFileGuardTests(unittest.TestCase):
    def test_suite_guard_keeps_tests_off_the_live_token_file(self) -> None:
        live = Path.home() / ".gemini" / "antigravity-cli" / "antigravity-oauth-token"
        self.assertNotEqual(AntigravityProvider._TOKEN_FILE_PATH, live)
        self.assertEqual(AntigravityProvider._load_file_token(), {})
