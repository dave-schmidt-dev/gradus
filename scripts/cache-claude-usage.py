#!/usr/bin/env python3
"""Persist Claude status-line rate limits as a credential-free atomic cache."""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import tempfile
import time
from pathlib import Path

DEFAULT_OUTPUT = Path(__file__).resolve().parent.parent / ".state" / "claude-usage.json"


def _bucket(payload: object, name: str) -> dict[str, float] | None:
    if not isinstance(payload, dict):
        raise ValueError("input must be a JSON object")
    rate_limits = payload.get("rate_limits")
    if rate_limits is None:
        return None
    if not isinstance(rate_limits, dict):
        raise ValueError("rate_limits must be an object")
    raw = rate_limits.get(name)
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise ValueError(f"{name} must be an object")

    used = raw.get("used_percentage")
    if not isinstance(used, (int, float)) or isinstance(used, bool):
        raise ValueError(f"{name}.used_percentage must be numeric")
    used_float = float(used)
    if not math.isfinite(used_float) or not 0 <= used_float <= 100:
        raise ValueError(f"{name}.used_percentage is out of range")

    result = {"used_percentage": used_float}
    resets_at = raw.get("resets_at")
    if resets_at is not None:
        if not isinstance(resets_at, (int, float)) or isinstance(resets_at, bool):
            raise ValueError(f"{name}.resets_at must be numeric")
        reset_float = float(resets_at)
        if not math.isfinite(reset_float) or reset_float <= 0:
            raise ValueError(f"{name}.resets_at is invalid")
        result["resets_at"] = reset_float
    return result


def _write_atomic(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=f"{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args(argv)
    try:
        source = json.load(sys.stdin)
        five_hour = _bucket(source, "five_hour")
        seven_day = _bucket(source, "seven_day")
        if five_hour is None and seven_day is None:
            return 0
        cache: dict[str, object] = {
            "schema_version": 1,
            "observed_at": time.time(),
        }
        if five_hour is not None:
            cache["five_hour"] = five_hour
        if seven_day is not None:
            cache["seven_day"] = seven_day
        _write_atomic(args.output, cache)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"claude usage cache unavailable: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
