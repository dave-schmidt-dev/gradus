"""SolidStart server-function probe support (OpenCode Go)."""

from __future__ import annotations

import json
from typing import Any

from ._base import ProbeFailure, _AuthRejected

_SEROVAL_CONSTANTS = {0: None, 1: None, 2: True, 3: False}


def _seroval_chunks(body: bytes) -> list[bytes]:
    if not body.startswith(b";0x"):
        return [body] if body else []
    chunks: list[bytes] = []
    rest = body
    while rest:
        if len(rest) < 12 or not rest.startswith(b";0x") or rest[11:12] != b";":
            break
        try:
            length = int(rest[3:11], 16)
        except ValueError:
            break
        chunks.append(rest[12 : 12 + length])
        rest = rest[12 + length :]
    return chunks


def _solidstart_js_to_json(js: str) -> str:
    import re

    s = js.strip()
    prefix_re = r"^\(\(self\.\$R=self\.\$R\|\|\{\}\)\[\"[^\"]+\"\]=\[\],\(\$R=>"
    suffix_re = r"\)\(\$R\[\"[^\"]+\"\]\)\)+$"
    s = re.sub(prefix_re, "", s)
    s = re.sub(suffix_re, "", s)
    s = re.sub(r"\$R\[[^\]]*\]\s*=\s*", "", s)
    s = re.sub(r"\$R\[[^\]]*\]", "null", s)
    s = re.sub(r"(?<=[{,\s])(\w+)\s*:", r'"\1":', s)
    return s


def _is_solidstart_js(body: bytes) -> bool:
    return b"(self.$R=" in body or b"server-fn:" in body


def _seroval_decode(body: bytes) -> Any:
    chunks = _seroval_chunks(body)
    if not chunks:
        return None

    chunk = chunks[0]

    if _is_solidstart_js(chunk):
        raw_text = chunk.decode("utf-8", errors="replace")
        if "new Error(" in raw_text:
            if (
                "actor of type" in raw_text
                or "not associated" in raw_text
                or "unauthorized" in raw_text.lower()
            ):
                raise _AuthRejected("session not associated with workspace")
            raise ProbeFailure("OpenCode Go server returned an error", raw_text[:500])
        try:
            json_str = _solidstart_js_to_json(raw_text)
            root = json.loads(json_str)
        except (json.JSONDecodeError, ValueError) as exc:
            raise ProbeFailure(
                "Invalid SolidStart JS response",
                raw_text[:500],
            ) from exc
    else:
        try:
            root = json.loads(chunk)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ProbeFailure(
                "Invalid seroval response",
                chunk[:500].decode("utf-8", "replace"),
            ) from exc

    if not isinstance(root, dict) or "t" not in root:
        return root

    raw_by_id: dict[int, Any] = {}

    def _index(node: Any) -> None:
        if not isinstance(node, dict) or "t" not in node:
            return
        ref = node.get("i")
        if isinstance(ref, int) and not isinstance(ref, bool):
            raw_by_id[ref] = node
        props = node.get("p")
        if isinstance(props, dict):
            for value in props.get("v") or []:
                _index(value)
        for key in ("a",):
            items = node.get(key)
            if isinstance(items, list):
                for item in items:
                    _index(item)
        fulfilled = node.get("f")
        if isinstance(fulfilled, dict):
            _index(fulfilled)

    _index(root)

    decoded_by_id: dict[int, Any] = {}

    def _decode(node: Any) -> Any:
        if not isinstance(node, dict) or "t" not in node:
            return node
        ref = node.get("i")
        if isinstance(ref, int) and not isinstance(ref, bool) and ref in decoded_by_id:
            return decoded_by_id[ref]
        kind = node.get("t")
        if kind == 0:
            value = node.get("s")
            result = float(value) if isinstance(value, str) else value
        elif kind == 1:
            result = node.get("s")
        elif kind == 2:
            result = _SEROVAL_CONSTANTS.get(node.get("s"))
        elif kind == 4:
            target = raw_by_id.get(node.get("i"))
            result = _decode(target) if target is not None else None
        elif kind == 5:
            result = node.get("s")
        elif kind == 9:
            result = [_decode(item) for item in node.get("a") or []]
        elif kind in (10, 11):
            props = node.get("p") or {}
            keys = props.get("k") or []
            values = props.get("v") or []
            result = {str(k): _decode(v) for k, v in zip(keys, values)}
        elif kind == 12:
            result = _decode(node.get("f"))
        else:
            result = None
        if isinstance(ref, int) and not isinstance(ref, bool):
            decoded_by_id[ref] = result
        return result

    return _decode(root)
