"""Provider helper tests."""

from __future__ import annotations

import json
import subprocess
import unittest
from datetime import datetime
from unittest.mock import MagicMock, patch

from gradus import snapshot as snapshot_module
from gradus.__main__ import _is_auth_error
from gradus.providers import (
    CopilotHttpProvider,
    ProbeFailure,
    ProviderSnapshot,
    VibeCodeProvider,
    _format_reset_time,
    _http_json,
    _seroval_decode,
    fetch_provider_snapshot,
)
from gradus.snapshot import _is_transient_probe_error


class ProviderHelperTests(unittest.TestCase):
    def test_copilot_monthly_reset_label_uses_local_time(self) -> None:
        label = CopilotHttpProvider._monthly_reset_label()
        self.assertTrue(label.startswith("Resets "))
        self.assertNotIn("UTC", label)
        self.assertIn(" at ", label)


class FetchProviderSnapshotTests(unittest.TestCase):
    def test_generic_provider_exception_uses_fixed_safe_error_and_debug_detail(self) -> None:
        sentinel = "provider-secret-sentinel"

        class FakeProvider:
            def fetch(self) -> None:
                raise RuntimeError(sentinel)

        snapshot = fetch_provider_snapshot("Codex", FakeProvider(), debug=True)

        self.assertFalse(snapshot.ok)
        self.assertEqual(snapshot.error, "provider probe failed")
        self.assertNotIn(sentinel, snapshot.error or "")
        self.assertEqual(snapshot.debug_detail, "RuntimeError")

        quiet_snapshot = fetch_provider_snapshot("Codex", FakeProvider(), debug=False)
        self.assertIsNone(quiet_snapshot.debug_detail)
        for build_payload in (
            snapshot_module.build_snapshot_payload,
            snapshot_module.build_snapshot_v2_payload,
        ):
            payload_json = json.dumps(build_payload([snapshot], datetime(2026, 1, 1)))
            self.assertNotIn(sentinel, payload_json)

    def test_status_serialization_exception_uses_fixed_safe_error_and_debug_detail(self) -> None:
        sentinel = "status-secret-sentinel"

        class FakeStatus:
            def to_dict(self) -> dict[str, object]:
                raise RuntimeError(sentinel)

        class FakeProvider:
            def fetch(self) -> FakeStatus:
                return FakeStatus()

        snapshot = fetch_provider_snapshot("Codex", FakeProvider(), debug=True)

        self.assertFalse(snapshot.ok)
        self.assertEqual(snapshot.error, "provider probe failed")
        self.assertNotIn(sentinel, snapshot.error or "")
        self.assertEqual(snapshot.debug_detail, "RuntimeError")

        quiet_snapshot = fetch_provider_snapshot("Codex", FakeProvider(), debug=False)
        self.assertIsNone(quiet_snapshot.debug_detail)
        for build_payload in (
            snapshot_module.build_snapshot_payload,
            snapshot_module.build_snapshot_v2_payload,
        ):
            payload_json = json.dumps(build_payload([snapshot], datetime(2026, 1, 1)))
            self.assertNotIn(sentinel, payload_json)

    def test_read_timeout_classifies_as_transient_not_a_hard_failure(self) -> None:
        """A urllib read timeout must reach the device as a retryable error.

        ``socket.timeout`` is ``TimeoutError`` on 3.10+, and ``TimeoutError``
        is NOT a subclass of ``urllib.error.URLError`` -- it is an ``OSError``.
        So ``_http_json``'s URLError branch never sees a *read* timeout and it
        lands in the generic catch-all, which used to flatten every exception
        to "provider probe failed". That string matches no transient marker, so
        `_merge_with_previous` declined to serve the last-known-good reading
        and a two-second network blip published a failure card to iPhone and
        iPad while the TUI, on its own cycle, looked fine.
        """
        import socket
        import urllib.error

        # The two facts the bug rests on, asserted rather than assumed. If a
        # future Python decouples these, raising `TimeoutError` below would
        # stop resembling what urllib actually raises and this test would
        # quietly stop testing the real path.
        self.assertIs(socket.timeout, TimeoutError)
        self.assertFalse(issubclass(TimeoutError, urllib.error.URLError))

        class FakeProvider:
            def fetch(self) -> None:
                raise TimeoutError("The read operation timed out")

        snapshot = fetch_provider_snapshot("Antigravity", FakeProvider(), debug=False)

        self.assertFalse(snapshot.ok)
        self.assertEqual(snapshot.error, "provider probe timed out")
        # The payoff: the classifier must accept what the catch-all emits.
        # Asserting the string alone would re-create the original gap, where
        # both halves were correct and only the seam between them was wrong.
        self.assertTrue(_is_transient_probe_error(snapshot))

    def test_connection_error_classifies_as_transient(self) -> None:
        class FakeProvider:
            def fetch(self) -> None:
                raise ConnectionResetError("Connection reset by peer")

        snapshot = fetch_provider_snapshot("Antigravity", FakeProvider(), debug=False)

        self.assertEqual(snapshot.error, "provider probe network error")
        self.assertTrue(_is_transient_probe_error(snapshot))

    def test_transient_mapping_still_withholds_the_exception_text(self) -> None:
        """Classifying by type must not become an excuse to publish the message.

        ``AntigravityProvider._load_keychain_token`` embeds `security`
        subprocess output in its exception, so raw text on ``error`` would push
        credential-adjacent strings through CloudKit to both devices. Type is
        safe to branch on; the message is withheld even from ``--debug``.
        """
        sentinel = "timeout-secret-sentinel"

        class FakeProvider:
            def fetch(self) -> None:
                raise TimeoutError(sentinel)

        snapshot = fetch_provider_snapshot("Antigravity", FakeProvider(), debug=True)

        self.assertEqual(snapshot.error, "provider probe timed out")
        self.assertNotIn(sentinel, snapshot.error or "")
        self.assertNotIn(sentinel, snapshot.debug_detail or "")

        quiet = fetch_provider_snapshot("Antigravity", FakeProvider(), debug=False)
        self.assertIsNone(quiet.debug_detail)
        for build_payload in (
            snapshot_module.build_snapshot_payload,
            snapshot_module.build_snapshot_v2_payload,
        ):
            payload_json = json.dumps(build_payload([snapshot], datetime(2026, 1, 1)))
            self.assertNotIn(sentinel, payload_json)

    def test_subprocess_timeout_keeps_debug_detail_off_the_snapshot_surface(self) -> None:
        """A CLI timeout is retryable, without command detail in debug."""
        sentinel = "credential-helper-timeout-detail"

        class FakeProvider:
            def fetch(self) -> None:
                raise subprocess.TimeoutExpired(["provider", sentinel], timeout=7)

        snapshot = fetch_provider_snapshot("Copilot", FakeProvider(), debug=True)

        self.assertFalse(snapshot.ok)
        self.assertEqual(snapshot.error, "provider probe timed out")
        self.assertNotIn(sentinel, snapshot.debug_detail or "")
        self.assertNotIn(sentinel, snapshot.error or "")

        quiet_snapshot = fetch_provider_snapshot("Copilot", FakeProvider(), debug=False)
        self.assertIsNone(quiet_snapshot.debug_detail)
        payload_json = json.dumps(
            snapshot_module.build_snapshot_payload([snapshot], datetime(2026, 1, 1))
        )
        self.assertNotIn(sentinel, payload_json)

    def test_headless_debug_detail_omits_the_dump_hint_it_cannot_honor(self) -> None:
        """Raw provider bodies stay private under headless and debug modes."""
        import gradus.providers as providers

        class FakeProvider:
            def fetch(self) -> None:
                raise ProbeFailure("HTTP 500", "raw body text")

        try:
            providers.set_headless(True)
            headless = fetch_provider_snapshot("Codex", FakeProvider(), debug=True)
        finally:
            providers.set_headless(False)

        self.assertNotIn("raw dump:", headless.debug_detail or "")
        self.assertIn("HTTP 500", headless.debug_detail or "")
        self.assertNotIn("raw body text", headless.debug_detail or "")

        interactive = fetch_provider_snapshot("Codex", FakeProvider(), debug=True)
        self.assertNotIn("raw dump:", interactive.debug_detail or "")
        self.assertNotIn("raw body text", interactive.debug_detail or "")

    def test_unrecognized_exception_type_stays_opaque(self) -> None:
        """Only the two known-retryable families get a specific message.

        Anything else keeps the opaque generic string, so a new failure mode
        cannot accidentally inherit "retry me" semantics it has not earned.
        """

        class FakeProvider:
            def fetch(self) -> None:
                raise ValueError("something structural is wrong")

        snapshot = fetch_provider_snapshot("Antigravity", FakeProvider(), debug=False)

        self.assertEqual(snapshot.error, "provider probe failed")
        self.assertFalse(_is_transient_probe_error(snapshot))


class NetworkFailureClassificationTests(unittest.TestCase):
    """Every provider must classify an unreachable network as *transient*.

    The contract this locks: a provider's failure message is not free prose,
    it is the input to ``snapshot._is_transient_probe_error``, which decides
    whether ``_merge_with_previous`` serves the last-known-good reading or
    publishes a failure card to iPhone and iPad. Classification has to run off
    the string because it also runs against snapshots read back from disk,
    where the original exception is long gone -- so provider wording is a de
    facto API, and this is the test that says so.

    It existed because nothing did. OpenCode Go and Vibe both caught
    ``URLError`` correctly and then described it in accurate English that
    matched no marker ("Could not reach opencode.ai"), so a DNS blip read as a
    hard failure on both devices. Cursor is included even though it has always
    been correct -- an untested correct case is one refactor from being an
    untested broken one.
    """

    def _dns_failure(self):
        import socket
        import urllib.error

        # A real resolver failure, not a synthetic string: gaierror is what
        # macOS actually raises when the network drops mid-probe.
        return urllib.error.URLError(socket.gaierror(8, "nodename nor servname provided"))

    def _assert_transient(self, snapshot: ProviderSnapshot, *, provider: str) -> None:
        self.assertFalse(snapshot.ok, f"{provider}: probe should have failed")
        self.assertTrue(
            _is_transient_probe_error(snapshot),
            f"{provider}: {snapshot.error!r} matches no transient marker, so a "
            f"network blip would publish a failure card instead of serving cache",
        )
        # A network error must not be mistaken for an auth problem: that would
        # offer the user a `login` fix action for a failure logging in cannot fix.
        self.assertFalse(_is_auth_error(snapshot), f"{provider}: misread as an auth error")

    def test_vibe_dns_failure_is_transient(self) -> None:
        provider = VibeCodeProvider(project_root="/nonexistent")
        provider._ory_name = "ory_session"
        provider._ory_value = "value"
        provider._csrf = "csrf"

        with patch("urllib.request.urlopen", side_effect=self._dns_failure()):
            snapshot = fetch_provider_snapshot("Vibe Code", provider, debug=False)

        self._assert_transient(snapshot, provider="Vibe Code")

    def test_catch_all_backstop_maps_urlerror_but_not_httperror(self) -> None:
        """Ordering guard inside ``_safe_probe_error``.

        ``HTTPError`` subclasses ``URLError``. If the URLError branch ran
        first, a 401 reaching the catch-all would classify as transient and
        ``_merge_with_previous`` would serve stale data forever while hiding a
        dead session -- silent staleness, worse than the failure card the
        transient mapping exists to prevent.
        """
        import urllib.error

        class Unreachable:
            def fetch(self_inner):
                raise self._dns_failure()

        class Unauthorized:
            def fetch(self_inner):
                raise urllib.error.HTTPError(
                    "https://example.invalid", 401, "Unauthorized", {}, None
                )

        transient = fetch_provider_snapshot("Codex", Unreachable(), debug=False)
        self.assertEqual(transient.error, "provider probe network error")
        self.assertTrue(_is_transient_probe_error(transient))

        opaque = fetch_provider_snapshot("Codex", Unauthorized(), debug=False)
        self.assertEqual(opaque.error, "provider probe failed")
        self.assertFalse(
            _is_transient_probe_error(opaque),
            "a 401 must not be served from cache -- that hides a dead session",
        )

    def test_shared_http_helper_dns_failure_is_transient(self) -> None:
        """Covers every provider that probes through ``_http_json``.

        Claude, Codex, Antigravity and Copilot share this one branch, so
        classifying it here classifies it for all four.
        """

        class FakeProvider:
            def fetch(self_inner):
                return _http_json("https://example.invalid/usage")

        with patch("urllib.request.urlopen", side_effect=self._dns_failure()):
            snapshot = fetch_provider_snapshot("Claude", FakeProvider(), debug=False)

        self._assert_transient(snapshot, provider="_http_json")


class FormatResetTimeTests(unittest.TestCase):
    def test_iso_string_with_z(self) -> None:
        result = _format_reset_time("2026-05-01T12:00:00Z")
        self.assertIsNotNone(result)
        assert result is not None
        self.assertTrue(result.startswith("Resets "))
        self.assertIn(" at ", result)

    def test_iso_string_without_z(self) -> None:
        result = _format_reset_time("2026-05-01T12:00:00+00:00")
        self.assertIsNotNone(result)
        assert result is not None
        self.assertTrue(result.startswith("Resets "))

    def test_epoch_seconds(self) -> None:
        # 2026-01-01 00:00:00 UTC = 1767225600
        result = _format_reset_time(1767225600)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertTrue(result.startswith("Resets "))

    def test_epoch_milliseconds(self) -> None:
        result = _format_reset_time(1767225600000)  # > 1e12 → treated as ms
        self.assertIsNotNone(result)
        assert result is not None
        self.assertTrue(result.startswith("Resets "))

    def test_none_input(self) -> None:
        self.assertIsNone(_format_reset_time(None))

    def test_invalid_string(self) -> None:
        self.assertIsNone(_format_reset_time("not-a-date"))


class HttpJsonHelperTests(unittest.TestCase):
    def test_success(self) -> None:
        mock_resp = MagicMock()
        mock_resp.read.return_value = b'{"ok": true}'
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        with patch("urllib.request.urlopen", return_value=mock_resp):
            result = _http_json("https://example.com/api")
        self.assertEqual(result, {"ok": True})

    def test_http_error_raises_probe_failure(self) -> None:
        import urllib.error

        with patch(
            "urllib.request.urlopen",
            side_effect=urllib.error.HTTPError(
                "https://example.com", 429, "Too Many Requests", {}, None
            ),
        ):
            with self.assertRaises(ProbeFailure) as ctx:
                _http_json("https://example.com/api")
        self.assertIn("429", str(ctx.exception))

    def test_network_error_raises_probe_failure(self) -> None:
        import urllib.error

        with patch(
            "urllib.request.urlopen",
            side_effect=urllib.error.URLError("connection refused"),
        ):
            with self.assertRaises(ProbeFailure):
                _http_json("https://example.com/api")

    def test_invalid_json_raises_probe_failure(self) -> None:
        mock_resp = MagicMock()
        mock_resp.read.return_value = b"not json"
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        with patch("urllib.request.urlopen", return_value=mock_resp):
            with self.assertRaises(ProbeFailure):
                _http_json("https://example.com/api")


def _seroval_stream(node_json: str) -> bytes:
    """Frame one seroval JSON node as a solid-start stream chunk."""
    payload = node_json.encode("utf-8")
    return b";0x" + f"{len(payload):08x}".encode("ascii") + b";" + payload


_SEROVAL_WORKSPACES = (
    '{"t":9,"i":0,"a":[{"t":10,"i":1,"p":{"k":["id","name","slug"],"v":['
    '{"t":1,"s":"wrk_a"},{"t":1,"s":"Personal"},{"t":1,"s":"personal"}]},"o":0}],"o":0}'
)


_SEROVAL_SUBSCRIPTION = (
    '{"t":10,"i":0,"p":{"k":["mine","useBalance","rollingUsage","weeklyUsage","monthlyUsage"],'
    '"v":[{"t":2,"s":2},{"t":2,"s":3},'
    '{"t":10,"i":1,"p":{"k":["status","resetInSec","usagePercent"],"v":['
    '{"t":1,"i":9,"s":"ok"},{"t":0,"s":18000},{"t":0,"s":25}]},"o":0},'
    '{"t":10,"i":2,"p":{"k":["status","resetInSec","usagePercent"],"v":['
    '{"t":4,"i":9},{"t":0,"s":400000},{"t":0,"s":10}]},"o":0},'
    '{"t":10,"i":3,"p":{"k":["status","resetInSec","usagePercent"],"v":['
    '{"t":4,"i":9},{"t":0,"s":1200000},{"t":0,"s":100}]},"o":0}]},"o":0}'
)


class SerovalDecodeTests(unittest.TestCase):
    """The console's SolidStart server functions answer in seroval cross-JSON."""

    def test_framed_object_array_decodes(self) -> None:
        result = _seroval_decode(_seroval_stream(_SEROVAL_WORKSPACES))
        self.assertEqual(result, [{"id": "wrk_a", "name": "Personal", "slug": "personal"}])

    def test_indexed_value_backreferences_resolve(self) -> None:
        result = _seroval_decode(_seroval_stream(_SEROVAL_SUBSCRIPTION))
        self.assertEqual(result["rollingUsage"]["status"], "ok")
        self.assertEqual(result["weeklyUsage"]["status"], "ok")
        self.assertEqual(result["monthlyUsage"]["status"], "ok")
        self.assertEqual(result["rollingUsage"]["resetInSec"], 18000)
        self.assertEqual(result["monthlyUsage"]["usagePercent"], 100)
        self.assertIs(result["mine"], True)
        self.assertIs(result["useBalance"], False)

    def test_null_constant_decodes_to_none(self) -> None:
        self.assertIsNone(_seroval_decode(_seroval_stream('{"t":2,"s":0}')))

    def test_unframed_json_body_passes_through(self) -> None:
        self.assertEqual(_seroval_decode(b'{"status":500}'), {"status": 500})

    def test_empty_body_decodes_to_none(self) -> None:
        self.assertIsNone(_seroval_decode(b""))

    def test_invalid_payload_raises_probe_failure(self) -> None:
        with self.assertRaises(ProbeFailure):
            _seroval_decode(b"\x00\xff not json")

    def test_solidstart_js_response_decodes(self) -> None:
        js_body = (
            b';0x00000090;((self.$R=self.$R||{})["server-fn:0"]=[],'
            b'($R=>$R[0]=[$R[1]={id:"wrk_123",name:"test",slug:null}])($R["server-fn:0"]))'
        )
        result = _seroval_decode(js_body)
        self.assertEqual(result, [{"id": "wrk_123", "name": "test", "slug": None}])


if __name__ == "__main__":
    unittest.main()
