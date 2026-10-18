"""Tests for OpenCode Console OAuth authentication and status probe."""

from __future__ import annotations

import json
import os
import sqlite3
import tempfile
import time
import unittest
import urllib.error
from datetime import datetime, timezone
from http.client import HTTPException
from pathlib import Path
from unittest.mock import MagicMock, patch

from gradus.parsing import OpenCodeGoStatus
from gradus.providers import OpenCodeGoProvider, ProbeFailure, fetch_provider_snapshot, set_headless
from gradus.providers.opencode_oauth import (
    NoRedirectHandler,
    OpenCodeOAuthCredential,
    _is_cloudflare_403,
    fetch_console_oauth_status,
    load_opencode_oauth_credential,
    parse_console_status_payload,
    validate_console_server,
)
from gradus.snapshot import build_snapshot_payload


def _create_synthetic_opencode_db(path: Path | str, rows: list[tuple[object, ...]]) -> None:
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE credential ("
        "id TEXT PRIMARY KEY, "
        "integration_id TEXT, "
        "label TEXT, "
        "value TEXT, "
        "connector_id TEXT, "
        "method_id TEXT, "
        "active INTEGER)"
    )
    for row in rows:
        conn.execute("INSERT INTO credential VALUES (?, ?, ?, ?, ?, ?, ?)", row)
    conn.commit()
    conn.close()


class OpenCodeOAuthTests(unittest.TestCase):
    def setUp(self) -> None:
        set_headless(False)
        guard = patch.object(OpenCodeGoProvider, "_DB_PATH", Path(os.devnull) / "opencode-test.db")
        guard.start()
        self.addCleanup(guard.stop)

    def tearDown(self) -> None:
        set_headless(False)

    def test_opencode_oauth_active_credential_selection_and_db_readonly(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
            db_path = Path(tmp.name)
            active_val = {
                "type": "oauth",
                "methodID": "device",
                "access": "access-token-active",
                "refresh": "refresh-token-active",
                "expires": int(time.time() * 1000) + 3600000,
                "metadata": {
                    "server": "https://opencode.ai/console",
                    "orgID": "org-active-123",
                    "orgName": "Engineering",
                },
            }
            inactive_val = {
                "type": "oauth",
                "methodID": "device",
                "access": "access-token-inactive",
                "refresh": "refresh-token-inactive",
                "expires": int(time.time() * 1000) + 3600000,
                "metadata": {"server": "https://opencode.ai/console"},
            }
            other_val = {"type": "oauth", "access": "other-token", "expires": 9999999999999}
            rows = [
                ("c-inactive", "opencode", "work", json.dumps(inactive_val), None, "device", 0),
                ("c-active", "opencode", "default", json.dumps(active_val), None, "device", 1),
                ("c-other", "github", "default", json.dumps(other_val), None, "oauth", 1),
            ]
            _create_synthetic_opencode_db(db_path, rows)
            stat_before = db_path.stat()

            cred = load_opencode_oauth_credential(db_path)
            self.assertIsNotNone(cred)
            assert cred is not None
            self.assertEqual(cred.access, "access-token-active")
            self.assertEqual(cred.server, "https://opencode.ai/console")
            self.assertEqual(cred.org_id, "org-active-123")

            stat_after = db_path.stat()
            self.assertEqual(stat_before.st_size, stat_after.st_size)
            self.assertEqual(stat_before.st_mtime_ns, stat_after.st_mtime_ns)

            # Confirm file opened with mode=ro denies writes
            ro_conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
            with self.assertRaisesRegex(sqlite3.OperationalError, "readonly"):
                ro_conn.execute(
                    "INSERT INTO credential VALUES ('x', 'y', 'z', '{}', null, null, 1)"
                )
            ro_conn.close()

    def test_opencode_oauth_fresh_vs_expired_tokens(self) -> None:
        now_ms = 1800000000000.0
        with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
            db_path = Path(tmp.name)
            # Expired token
            expired_val = {
                "type": "oauth",
                "methodID": "device",
                "access": "expired-access-token",
                "refresh": "refresh-token",
                "expires": int(now_ms - 5000),
                "metadata": {"server": "https://opencode.ai/console"},
            }
            _create_synthetic_opencode_db(
                db_path,
                [("c-exp", "opencode", "default", json.dumps(expired_val), None, "device", 1)],
            )

            with self.assertRaisesRegex(
                ProbeFailure,
                "OpenCode OAuth token expired: open OpenCode to refresh",
            ):
                load_opencode_oauth_credential(db_path, now_ms=now_ms)

            provider = OpenCodeGoProvider(db_path)
            with (
                patch.object(provider, "_load_keychain_api_key") as load_key,
                patch("time.time", return_value=now_ms / 1000.0),
                self.assertRaisesRegex(
                    ProbeFailure,
                    "OpenCode OAuth token expired: open OpenCode to refresh",
                ),
            ):
                provider.fetch()
            load_key.assert_not_called()
            self.assertEqual(provider._api_key, "")

    def test_opencode_oauth_untrusted_server_rejected(self) -> None:
        for untrusted in (
            "https://evil.com/console",
            "http://opencode.ai/console",
            "https://opencode.ai/other",
            "https://opencode.ai",
        ):
            with self.subTest(server=untrusted):
                with self.assertRaises(ProbeFailure) as raised:
                    validate_console_server(untrusted)
                self.assertIn("OpenCode OAuth server is untrusted", str(raised.exception))
                self.assertNotIn(untrusted, str(raised.exception))

        with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
            db_path = Path(tmp.name)
            untrusted_val = {
                "type": "oauth",
                "methodID": "device",
                "access": "token-1",
                "refresh": "refresh-1",
                "expires": int(time.time() * 1000) + 3600000,
                "metadata": {"server": "https://phishing.example.com/console"},
            }
            _create_synthetic_opencode_db(
                db_path,
                [("c-1", "opencode", "default", json.dumps(untrusted_val), None, "device", 1)],
            )
            with self.assertRaisesRegex(ProbeFailure, "OpenCode OAuth server is untrusted"):
                load_opencode_oauth_credential(db_path)

    def test_opencode_oauth_multiple_active_ambiguity(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
            db_path = Path(tmp.name)
            val1 = {
                "type": "oauth",
                "access": "token-1",
                "refresh": "",
                "expires": int(time.time() * 1000) + 3600000,
                "metadata": {"server": "https://opencode.ai/console"},
            }
            val2 = {
                "type": "oauth",
                "access": "token-2",
                "refresh": "",
                "expires": int(time.time() * 1000) + 3600000,
                "metadata": {"server": "https://opencode.ai/console"},
            }
            rows = [
                ("c-1", "opencode", "acc1", json.dumps(val1), None, "device", 1),
                ("c-2", "opencode", "acc2", json.dumps(val2), None, "device", 1),
            ]
            _create_synthetic_opencode_db(db_path, rows)

            with self.assertRaisesRegex(
                ProbeFailure,
                "OpenCode OAuth credential selection ambiguous: multiple active credentials",
            ):
                load_opencode_oauth_credential(db_path)

            provider = OpenCodeGoProvider(db_path)
            with (
                patch.object(provider, "_load_keychain_api_key") as load_key,
                self.assertRaisesRegex(ProbeFailure, "ambiguous: multiple active credentials"),
            ):
                provider.fetch()
            load_key.assert_not_called()

    def test_opencode_oauth_request_uses_exact_origin_and_org_header(self) -> None:
        cred_with_org = OpenCodeOAuthCredential(
            access="bearer-test-token",
            expires_ms=int(time.time() * 1000) + 3600000,
            server="https://opencode.ai/console",
            org_id="org-enterprise-456",
        )
        fake_payload = {
            "access": {
                "meters": {
                    "fiveHour": {
                        "usedMicroCents": 1000,
                        "limitMicroCents": 10000,
                        "resetsAt": "2030-01-01T00:00:00Z",
                    }
                }
            }
        }
        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps(fake_payload).encode("utf-8")
        mock_resp.__enter__.return_value = mock_resp
        mock_resp.__exit__.return_value = False

        mock_opener = MagicMock()
        mock_opener.open.return_value = mock_resp

        status = fetch_console_oauth_status(cred_with_org, opener=mock_opener)
        self.assertEqual(status.five_hour_percent_left, 90.0)

        req = mock_opener.open.call_args[0][0]
        self.assertEqual(req.full_url, "https://opencode.ai/console/api/go/status")
        self.assertEqual(req.get_method(), "GET")
        self.assertEqual(req.get_header("Authorization"), "Bearer bearer-test-token")
        self.assertEqual(req.get_header("X-org-id"), "org-enterprise-456")
        self.assertEqual(req.get_header("User-agent"), "gradus (opencode-go quota probe)")

        # When org_id is None, x-org-id header must not be set
        cred_no_org = OpenCodeOAuthCredential(
            access="bearer-no-org",
            expires_ms=int(time.time() * 1000) + 3600000,
            server="https://opencode.ai/console",
            org_id=None,
        )
        fetch_console_oauth_status(cred_no_org, opener=mock_opener)
        req2 = mock_opener.open.call_args[0][0]
        self.assertFalse(req2.has_header("X-org-id"))

    def test_opencode_oauth_redirects_denied(self) -> None:
        handler = NoRedirectHandler()
        dummy_req = urllib.request.Request("https://opencode.ai/console/api/go/status")
        self.assertIsNone(
            handler.redirect_request(dummy_req, None, 302, "Found", {}, "http://evil.com")
        )

        cred = OpenCodeOAuthCredential(
            access="bearer-token",
            expires_ms=int(time.time() * 1000) + 3600000,
            server="https://opencode.ai/console",
        )
        mock_opener = MagicMock()
        mock_opener.open.side_effect = urllib.error.HTTPError(
            "https://opencode.ai/console/api/go/status",
            302,
            "Found",
            {},
            None,
        )
        with self.assertRaisesRegex(ProbeFailure, "redirects denied"):
            fetch_console_oauth_status(cred, opener=mock_opener)

    def test_opencode_oauth_legacy_fallback_only_when_oauth_absent(self) -> None:
        # Nonexistent DB falls back to Keychain
        provider = OpenCodeGoProvider(Path("/nonexistent/opencode.db"))
        with patch.object(
            provider, "_load_keychain_api_key", return_value="fallback-key"
        ) as load_key:
            provider._acquire()
            self.assertEqual(provider._api_key, "fallback-key")
            self.assertIsNone(provider._oauth_credential)
            load_key.assert_called_once()

        # DB with no opencode rows falls back to Keychain
        with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
            db_path = Path(tmp.name)
            _create_synthetic_opencode_db(db_path, [])
            provider2 = OpenCodeGoProvider(db_path)
            with patch.object(
                provider2, "_load_keychain_api_key", return_value="fallback-key2"
            ) as load_key2:
                provider2._acquire()
                self.assertEqual(provider2._api_key, "fallback-key2")
                self.assertIsNone(provider2._oauth_credential)
                load_key2.assert_called_once()

    def test_opencode_oauth_401_no_key_fallback(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
            db_path = Path(tmp.name)
            valid_val = {
                "type": "oauth",
                "access": "revoked-token",
                "refresh": "refresh-token",
                "expires": int(time.time() * 1000) + 3600000,
                "metadata": {"server": "https://opencode.ai/console"},
            }
            _create_synthetic_opencode_db(
                db_path,
                [("c-1", "opencode", "default", json.dumps(valid_val), None, "device", 1)],
            )

            provider = OpenCodeGoProvider(db_path)
            error_401 = urllib.error.HTTPError(
                "https://opencode.ai/console/api/go/status",
                401,
                "Unauthorized",
                {},
                None,
            )
            mock_opener = MagicMock()
            mock_opener.open.side_effect = error_401

            with (
                patch(
                    "gradus.providers.opencode_oauth.urllib.request.build_opener",
                    return_value=mock_opener,
                ),
                patch.object(provider, "_load_keychain_api_key") as load_key,
                self.assertRaisesRegex(
                    ProbeFailure,
                    "OpenCode OAuth session expired or revoked: reconnect OpenCode Console",
                ),
            ):
                provider.fetch()

            load_key.assert_not_called()
            self.assertEqual(provider._api_key, "")

    def test_opencode_oauth_cloudflare_403_classified_access_blocked(self) -> None:
        cf_body = json.dumps(
            {
                "type": "https://developers.cloudflare.com/ruleset-engine/rules-language/fields/error-1010/",
                "title": "Error 1010: Access denied",
                "status": 403,
                "detail": "The site owner has blocked access based on your browser signature",
            }
        ).encode("utf-8")

        mock_error = urllib.error.HTTPError(
            "https://opencode.ai/console/api/go/status",
            403,
            "Forbidden",
            {},
            None,
        )
        mock_error.read = MagicMock(return_value=cf_body)
        self.assertTrue(_is_cloudflare_403(mock_error))

        cred = OpenCodeOAuthCredential(
            access="token-cf",
            expires_ms=int(time.time() * 1000) + 3600000,
            server="https://opencode.ai/console",
        )
        mock_opener = MagicMock()
        mock_opener.open.side_effect = mock_error

        with self.assertRaises(ProbeFailure) as raised:
            fetch_console_oauth_status(cred, opener=mock_opener)

        err_msg = str(raised.exception)
        self.assertIn("access blocked", err_msg.lower())
        self.assertNotIn("API key rejected", err_msg)
        self.assertNotIn("token-cf", err_msg)
        self.assertNotIn("browser signature", err_msg)
        self.assertNotIn("error-1010", err_msg)

    def test_opencode_oauth_generic_403_does_not_assert_rejected_credentials(self) -> None:
        generic_error = urllib.error.HTTPError(
            "https://opencode.ai/console/api/go/status",
            403,
            "Forbidden",
            {},
            None,
        )
        generic_error.read = MagicMock(return_value=b'{"error": "permission_denied"}')
        self.assertFalse(_is_cloudflare_403(generic_error))

        cred = OpenCodeOAuthCredential(
            access="token-perm",
            expires_ms=int(time.time() * 1000) + 3600000,
            server="https://opencode.ai/console",
        )
        mock_opener = MagicMock()
        mock_opener.open.side_effect = generic_error

        with self.assertRaises(ProbeFailure) as raised:
            fetch_console_oauth_status(cred, opener=mock_opener)

        err_msg = str(raised.exception)
        self.assertIn("permission denied", err_msg.lower())
        self.assertNotIn("API key rejected", err_msg)
        self.assertNotIn("token-perm", err_msg)

    def test_opencode_oauth_strict_quota_mapping(self) -> None:
        payload = {
            "access": {
                "meters": {
                    "fiveHour": {
                        "usedMicroCents": 1200000,
                        "limitMicroCents": 10000000,
                        "resetsAt": "2030-01-02T03:04:05Z",
                    },
                    "week": {
                        "usedMicroCents": 3400000,
                        "limitMicroCents": 10000000,
                        "resetsAt": "2030-01-03T03:04:05Z",
                    },
                    "month": {
                        "usedMicroCents": 5600000,
                        "limitMicroCents": 10000000,
                    },
                },
                "endsAt": "2030-01-04T03:04:05Z",
            }
        }
        status = parse_console_status_payload(payload)
        self.assertEqual(status.five_hour_percent_left, 88.0)
        self.assertIsNotNone(status.five_hour_reset)
        self.assertEqual(status.weekly_percent_left, 66.0)
        self.assertIsNotNone(status.weekly_reset)
        self.assertEqual(status.monthly_percent_left, 44.0)
        self.assertIsNotNone(status.monthly_reset)
        self.assertIsNone(status.zen_credit)

    def test_opencode_oauth_partial_and_invalid_windows(self) -> None:
        # Partial window: only fiveHour present
        partial_payload = {
            "access": {
                "meters": {
                    "fiveHour": {
                        "usedMicroCents": 2000000,
                        "limitMicroCents": 10000000,
                        "resetsAt": "2030-01-02T03:04:05Z",
                    }
                }
            }
        }
        status = parse_console_status_payload(partial_payload)
        self.assertEqual(status.five_hour_percent_left, 80.0)
        self.assertIsNone(status.weekly_percent_left)
        self.assertIsNone(status.monthly_percent_left)
        self.assertIsNone(status.weekly_reset)
        self.assertIsNone(status.monthly_reset)

        # Over-quota clamp: used > limit -> 0.0% left
        over_payload = {
            "access": {
                "meters": {
                    "fiveHour": {
                        "usedMicroCents": 12000000,
                        "limitMicroCents": 10000000,
                    }
                }
            }
        }
        status_over = parse_console_status_payload(over_payload)
        self.assertEqual(status_over.five_hour_percent_left, 0.0)

        # Null access raises typed subscription unavailable
        with self.assertRaisesRegex(
            ProbeFailure, "subscription unavailable: no active subscription"
        ):
            parse_console_status_payload({"access": None})

        # Reject booleans and negative limits
        invalid_meter_payload = {
            "access": {
                "meters": {
                    "fiveHour": {"usedMicroCents": True, "limitMicroCents": 1000},
                    "week": {"usedMicroCents": 100, "limitMicroCents": -500},
                    "month": {"usedMicroCents": 100, "limitMicroCents": False},
                }
            }
        }
        with self.assertRaisesRegex(ProbeFailure, "no recognizable windows"):
            parse_console_status_payload(invalid_meter_payload)

    def test_opencode_oauth_token_sentinel_absent_in_exceptions_and_snapshots(self) -> None:
        sentinel = "secret-token-must-not-leak-12345"
        cred = OpenCodeOAuthCredential(
            access=sentinel,
            expires_ms=int(time.time() * 1000) + 3600000,
            server="https://opencode.ai/console",
            org_id="org-789",
        )
        self.assertNotIn(sentinel, repr(cred))

        status = OpenCodeGoStatus(
            five_hour_percent_left=75.0,
            five_hour_reset=None,
            weekly_percent_left=None,
            weekly_reset=None,
            monthly_percent_left=None,
            monthly_reset=None,
            zen_credit=None,
            raw_text=json.dumps({"access": {"meters": {}}}),
        )

        class StubProvider:
            def fetch(self) -> OpenCodeGoStatus:
                return status

        snap = fetch_provider_snapshot("OpenCode Go", StubProvider(), debug=True)
        self.assertNotIn(sentinel, status.raw_text)
        self.assertNotIn(sentinel, json.dumps(snap.data or {}))
        payload = json.dumps(build_snapshot_payload([snap], datetime.now(timezone.utc)))
        self.assertNotIn(sentinel, payload)

        # When probe fails with exception, ensure sentinel does not escape
        class ErrorProvider:
            def fetch(self) -> OpenCodeGoStatus:
                raise ProbeFailure("failed probe", sentinel)

        err_snap = fetch_provider_snapshot("OpenCode Go", ErrorProvider(), debug=True)
        self.assertNotIn(sentinel, err_snap.error or "")
        self.assertNotIn(sentinel, err_snap.debug_detail or "")
        self.assertNotIn(sentinel, json.dumps(err_snap.data or {}))

    def test_opencode_oauth_headless_zero_side_effects(self) -> None:
        set_headless(True)
        with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
            db_path = Path(tmp.name)
            valid_val = {
                "type": "oauth",
                "access": "token-headless",
                "refresh": "",
                "expires": int(time.time() * 1000) + 3600000,
                "metadata": {"server": "https://opencode.ai/console"},
            }
            _create_synthetic_opencode_db(
                db_path,
                [("c-1", "opencode", "default", json.dumps(valid_val), None, "device", 1)],
            )
            provider = OpenCodeGoProvider(db_path)
            with self.assertRaisesRegex(ProbeFailure, "auth required: no cached credentials"):
                provider.fetch()
            self.assertIsNone(provider._oauth_credential)
            self.assertEqual(provider._api_key, "")

    def test_opencode_oauth_reloads_rotated_token_each_cycle(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "opencode.db"
            value = {"type": "oauth", "access": "first-fixture-token", "expires": 9999999999999}
            rows = [(str(i), "opencode", "old", "{}", None, None, 0) for i in range(20)]
            rows.append(("active", "opencode", "selected", json.dumps(value), None, "device", 1))
            _create_synthetic_opencode_db(path, rows)
            provider = OpenCodeGoProvider(path)
            with patch("gradus.providers.opencode_go.fetch_console_oauth_status") as fetch:
                provider.fetch()
                self.assertEqual(fetch.call_args.args[0].access, value["access"])
                value["access"] = "rotated-fixture-token"
                conn = sqlite3.connect(path)
                conn.execute(
                    "UPDATE credential SET value = ? WHERE id = 'active'", (json.dumps(value),)
                )
                conn.commit()
                conn.close()
                provider.fetch()
                self.assertEqual(fetch.call_args.args[0].access, value["access"])
                self.assertEqual(fetch.call_count, 2)

    def test_opencode_oauth_database_error_does_not_fall_back_to_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "corrupt.db"
            path.write_bytes(b"not a sqlite database")
            provider = OpenCodeGoProvider(path)
            with patch.object(provider, "_load_keychain_api_key") as key:
                with self.assertRaisesRegex(ProbeFailure, "database unavailable"):
                    provider.fetch()
                key.assert_not_called()

    def test_opencode_oauth_decimal_meter_strings(self) -> None:
        status = parse_console_status_payload(
            {
                "access": {
                    "meters": {
                        "fiveHour": {
                            "usedMicroCents": "250000000",
                            "limitMicroCents": "1000000000",
                        },
                        "week": {"usedMicroCents": "nan", "limitMicroCents": "1000"},
                    }
                }
            }
        )
        self.assertEqual(status.five_hour_percent_left, 75.0)
        self.assertIsNone(status.weekly_percent_left)

    def test_opencode_oauth_network_errors_do_not_echo_credentials(self) -> None:
        sentinel = "fixture-credential-must-stay-private"
        credential = OpenCodeOAuthCredential(sentinel, 9999999999999, "https://opencode.ai/console")
        for error in (urllib.error.URLError(sentinel), OSError(sentinel), HTTPException(sentinel)):
            opener = MagicMock()
            opener.open.side_effect = error
            with (
                self.subTest(error=type(error).__name__),
                self.assertRaises(ProbeFailure) as raised,
            ):
                fetch_console_oauth_status(credential, opener=opener)
            self.assertNotIn(sentinel, str(raised.exception))

    def test_opencode_legacy_cloudflare_block_retains_key(self) -> None:
        provider = OpenCodeGoProvider()
        provider._api_key = "synthetic-key"
        error = urllib.error.HTTPError("https://opencode.ai", 403, "Forbidden", {}, None)
        error.read = MagicMock(return_value=b'{"title":"Error 1010: Access denied"}')
        with patch("urllib.request.OpenerDirector.open", side_effect=error):
            with self.assertRaisesRegex(ProbeFailure, "blocked"):
                provider.fetch()
        self.assertEqual(provider._api_key, "synthetic-key")

    def test_opencode_oversized_response_is_rejected(self) -> None:
        response = MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = b" " * 65537
        opener = MagicMock()
        opener.open.return_value = response
        credential = OpenCodeOAuthCredential(
            "fixture", 9999999999999, "https://opencode.ai/console"
        )
        with self.assertRaisesRegex(ProbeFailure, "too large"):
            fetch_console_oauth_status(credential, opener=opener)
        provider = OpenCodeGoProvider()
        provider._api_key = "synthetic-key"
        with patch("urllib.request.OpenerDirector.open", return_value=response):
            with self.assertRaisesRegex(ProbeFailure, "too large"):
                provider.fetch()

    def test_opencode_oauth_huge_expiry_is_typed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "opencode.db"
            value = {"type": "oauth", "access": "fixture", "expires": 10**400}
            _create_synthetic_opencode_db(
                path, [("active", "opencode", "test", json.dumps(value), None, "device", 1)]
            )
            with self.assertRaisesRegex(ProbeFailure, "invalid expiry"):
                load_opencode_oauth_credential(path)

    def test_opencode_permission_body_is_not_inferred_cloudflare(self) -> None:
        error = urllib.error.HTTPError("https://opencode.ai", 403, "Forbidden", {}, None)
        error.read = MagicMock(return_value=b'{"title":"Access denied","detail":"Account blocked"}')
        self.assertFalse(_is_cloudflare_403(error))


if __name__ == "__main__":
    unittest.main()
