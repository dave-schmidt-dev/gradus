"""Shared App Store Connect API helpers (JWT auth + thin HTTP wrapper).

Requires APP_STORE_CONNECT_API_KEY (.p8 contents), APP_STORE_CONNECT_KEY_ID,
APP_STORE_CONNECT_ISSUER_ID in the environment (inject via bws-run). Run
consuming scripts with:
    bws-run -- uv run --with pyjwt --with cryptography app/<script>.py
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

API_BASE = "https://api.appstoreconnect.apple.com/v1"


def make_token() -> str:
    private_key = os.environ["APP_STORE_CONNECT_API_KEY"]
    key_id = os.environ["APP_STORE_CONNECT_KEY_ID"]
    issuer_id = os.environ["APP_STORE_CONNECT_ISSUER_ID"]
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer_id, "iat": now, "exp": now + 1190, "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def call(token: str, method: str, path: str, body: dict | None = None) -> dict | None:
    url = path if path.startswith("http") else f"{API_BASE}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        print(f"FAIL: {method} {url} -> HTTP {e.code}", file=sys.stderr)
        print(e.read().decode(errors="replace"), file=sys.stderr)
        raise
