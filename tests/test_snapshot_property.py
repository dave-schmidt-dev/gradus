"""Property-based tests for snapshot normalization invariants."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from hypothesis import given
from hypothesis import strategies as st

from gradus.providers import _PROVIDER_REGISTRY, ProviderSnapshot
from gradus.snapshot import (
    _UNSAFE_JSON,
    CANONICAL_PROVIDERS,
    SAFE_DATA_KEYS,
    WINDOW_SPECS,
    _build_snapshot_payload,
    _build_windows,
    _is_fresh_retained_entry,
    _json_safe_value,
    _sanitize_prior_entry,
    local_iso,
    project_data,
)

provider_names = st.sampled_from(list(_PROVIDER_REGISTRY.keys()))


def _snapshot_strategy(ok: bool | None = None):
    return st.builds(
        ProviderSnapshot,
        name=provider_names,
        ok=st.booleans() if ok is None else st.just(ok),
        source=st.text(max_size=20),
        data=st.one_of(
            st.none(),
            st.dictionaries(
                keys=st.text(max_size=20),
                values=st.one_of(
                    st.none(),
                    st.integers(),
                    st.floats(allow_nan=True, allow_infinity=True),
                    st.text(max_size=20),
                    st.booleans(),
                    st.lists(st.integers()),
                ),
            ),
        ),
        error=st.one_of(st.none(), st.text(max_size=100)),
        cached_since=st.one_of(st.none(), st.datetimes()),
    )


class TestSnapshotInvariants:
    """Property-based invariants for the snapshot normalization pipeline."""

    @given(snapshot=_snapshot_strategy())
    def test_build_windows_never_raises(self, snapshot):
        now = datetime.now(timezone.utc)
        _build_windows(snapshot, now, WINDOW_SPECS)

    @given(snapshot=_snapshot_strategy())
    def test_project_data_only_safe_keys(self, snapshot):
        result = project_data(snapshot)
        for key in result:
            assert key in SAFE_DATA_KEYS

    @given(snapshots=st.lists(_snapshot_strategy()))
    def test_payload_has_canonical_providers_count(self, snapshots):
        now = datetime.now(timezone.utc)
        payload = _build_snapshot_payload(
            snapshots,
            now,
            schema_version=1,
            specs_by_provider=WINDOW_SPECS,
        )
        providers = payload["providers"]
        expected = CANONICAL_PROVIDERS()
        assert len(providers) == len(expected)
        for i, name in enumerate(expected):
            assert providers[i]["name"] == name

    @given(
        value=st.one_of(
            st.just(float("nan")),
            st.just(float("inf")),
            st.just(float("-inf")),
            st.builds(object),
            st.tuples(st.integers()),
        )
    )
    def test_json_safe_value_rejects_problematic(self, value):
        assert _json_safe_value(value) is _UNSAFE_JSON

    def test_sanitize_prior_entry_valid(self):
        entry = {
            "name": "Codex",
            "ok": True,
            "error": None,
            "windows": [
                {
                    "id": "five_hour",
                    "percent_left": 75.0,
                    "reset_iso": "2026-03-14T13:22:30+00:00",
                    "window_hours": 5.0,
                    "pace_delta": 0.0,
                },
            ],
            "data": {"five_hour_percent_left": 75},
            "observed_at": "2026-03-14T12:00:00+00:00",
        }
        result = _sanitize_prior_entry(
            "Codex", entry, allowed_window_ids=frozenset({"five_hour", "weekly"})
        )
        assert isinstance(result, dict)
        assert result["name"] == "Codex"
        assert result["ok"] is True
        assert result["error"] is None
        assert result["observed_at"] == "2026-03-14T12:00:00+00:00"

    def test_sanitize_prior_entry_legacy_shape_falls_back_to_provided_observed_at(self):
        """A pre-P-BUG-1 prior (no observed_at key) still validates when the
        caller supplies a fallback (the prior payload's top-level updated_at).
        """
        entry = {
            "name": "Codex",
            "ok": True,
            "error": None,
            "windows": [],
            "data": {},
        }
        result = _sanitize_prior_entry(
            "Codex",
            entry,
            allowed_window_ids=frozenset({"five_hour", "weekly"}),
            fallback_observed_at="2026-03-14T12:00:00+00:00",
        )
        assert isinstance(result, dict)
        assert result["observed_at"] == "2026-03-14T12:00:00+00:00"

    @given(
        entry=st.one_of(
            st.none(),
            st.integers(),
            st.text(),
            st.dictionaries(
                keys=st.sampled_from(["name", "ok", "error", "data", "windows", "extra"]),
                values=st.text(),
                min_size=1,
            ),
        )
    )
    def test_sanitize_prior_entry_invalid(self, entry):
        result = _sanitize_prior_entry(
            "Codex", entry, allowed_window_ids=frozenset({"five_hour", "weekly"})
        )
        assert result is None

    @given(age_milliseconds=st.integers(min_value=-600_000, max_value=600_000))
    def test_retained_entry_freshness_is_exactly_the_300_second_window(self, age_milliseconds):
        publish_time = datetime(2026, 3, 14, 8, 22, 30, tzinfo=timezone.utc)
        observed_at = publish_time - timedelta(milliseconds=age_milliseconds)
        entry = {"observed_at": local_iso(observed_at)}
        assert _is_fresh_retained_entry(entry, publish_time) is (0 <= age_milliseconds < 300_000)

    @given(observed_at=st.sampled_from([None, "malformed", "2026-03-14T08:22:30"]))
    def test_retained_entry_invalid_observation_fails_closed(self, observed_at):
        publish_time = datetime(2026, 3, 14, 8, 22, 30, tzinfo=timezone.utc)
        assert not _is_fresh_retained_entry({"observed_at": observed_at}, publish_time)
