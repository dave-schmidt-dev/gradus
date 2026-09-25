"""Isolated macOS file-Keychain identity lineage for banked observations.

Only the short-lived helper handles the Keychain key and raw identity. Its
stdout is a fixed status plus a random generation UUID, never key material.
"""

from __future__ import annotations

import ctypes
import hashlib
import hmac
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

from .paths import RUNTIME_PATHS

_CACHE_NAME = "banked-identity-v1.json"
_ACCOUNT = b"gradus-banked-observation"
_SERVICE = {
    "source": b"com.zerodelta.gradus.banked.source.v1",
    "installed": b"com.zerodelta.gradus.banked.installed.v1",
}
_BACKOFF_SECONDS = {"denied": 3600, "timeout": 600, "failed": 600}
_DENIED_OSSTATUS = {-25308, -25293, -128}


class BankedAccessDenied(RuntimeError):
    """Security.framework explicitly refused noninteractive access."""


def _raise_keychain_failure(code: int) -> None:
    if code in _DENIED_OSSTATUS:
        raise BankedAccessDenied("keychain access denied")
    raise RuntimeError("keychain operation failed")


def _cache_path() -> Path:
    return RUNTIME_PATHS.private_cache_path(_CACHE_NAME)


def _read_cache() -> dict[str, object]:
    try:
        path = _cache_path()
        if path.stat().st_mode & 0o077:
            return {}
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return {}
    return value if isinstance(value, dict) else {}


def _write_cache(value: dict[str, object]) -> None:
    import tempfile

    path = _cache_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _failure(kind: str) -> None:
    previous = _read_cache()
    _write_cache(
        {
            "digest": previous.get("digest"),
            "generation": previous.get("generation"),
            "retry_reason": kind,
            "retry_after": time.time() + _BACKOFF_SECONDS[kind],
        }
    )


class SecurityAdapter:
    """Minimal Security.framework adapter; never uses the shell `security` CLI."""

    def __init__(self) -> None:
        self.lib = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
        self.core = ctypes.CDLL(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        )
        self.lib.SecKeychainSetUserInteractionAllowed.argtypes = [ctypes.c_bool]
        self.lib.SecKeychainSetUserInteractionAllowed.restype = ctypes.c_int32
        self.lib.SecKeychainCopyDefault.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        self.lib.SecKeychainCopyDefault.restype = ctypes.c_int32
        self.lib.SecKeychainFindGenericPassword.argtypes = [
            ctypes.c_void_p,
            ctypes.c_uint32,
            ctypes.c_char_p,
            ctypes.c_uint32,
            ctypes.c_char_p,
            ctypes.POINTER(ctypes.c_uint32),
            ctypes.POINTER(ctypes.c_void_p),
            ctypes.c_void_p,
        ]
        self.lib.SecKeychainFindGenericPassword.restype = ctypes.c_int32
        self.lib.SecKeychainAddGenericPassword.argtypes = [
            ctypes.c_void_p,
            ctypes.c_uint32,
            ctypes.c_char_p,
            ctypes.c_uint32,
            ctypes.c_char_p,
            ctypes.c_uint32,
            ctypes.c_void_p,
            ctypes.c_void_p,
        ]
        self.lib.SecKeychainAddGenericPassword.restype = ctypes.c_int32
        self.lib.SecKeychainItemFreeContent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self.lib.SecKeychainItemFreeContent.restype = ctypes.c_int32
        self.core.CFRelease.argtypes = [ctypes.c_void_p]

    def get_or_create(self, service: bytes, *, attended: bool) -> bytes:
        # This must precede even SecKeychainCopyDefault. A background cycle
        # cannot invoke SecurityAgent or display an ACL dialog.
        code = self.lib.SecKeychainSetUserInteractionAllowed(attended)
        if code != 0:
            _raise_keychain_failure(code)
        keychain = ctypes.c_void_p()
        code = self.lib.SecKeychainCopyDefault(ctypes.byref(keychain))
        if code != 0:
            _raise_keychain_failure(code)
        try:
            length = ctypes.c_uint32()
            content = ctypes.c_void_p()
            code = self.lib.SecKeychainFindGenericPassword(
                keychain,
                len(service),
                service,
                len(_ACCOUNT),
                _ACCOUNT,
                ctypes.byref(length),
                ctypes.byref(content),
                None,
            )
            if code == 0:
                try:
                    key = ctypes.string_at(content, length.value)
                finally:
                    self.lib.SecKeychainItemFreeContent(None, content)
                if len(key) != 32:
                    raise RuntimeError("invalid key item")
                return key
            if code != -25300:
                _raise_keychain_failure(code)
            key = os.urandom(32)
            buffer = ctypes.create_string_buffer(key)
            code = self.lib.SecKeychainAddGenericPassword(
                keychain,
                len(service),
                service,
                len(_ACCOUNT),
                _ACCOUNT,
                len(key),
                ctypes.cast(buffer, ctypes.c_void_p),
                None,
            )
            if code != 0:
                _raise_keychain_failure(code)
            return key
        finally:
            self.core.CFRelease(keychain)


def _identity_bytes(user_id: str, account_id: str | None) -> bytes:
    # Framed canonical tuple prevents delimiter and absent-field collisions.
    return json.dumps([user_id, account_id], ensure_ascii=True, separators=(",", ":")).encode()


def helper_main(*, attended: bool = False, adapter: SecurityAdapter | None = None) -> int:
    """Run inside the isolated child process; stdin is the only identity channel."""
    try:
        if attended:
            identity: dict[str, object] = {}
        else:
            identity = json.loads(sys.stdin.buffer.read(4096))
            user = identity.get("user_id")
            account = identity.get("account_id")
            if not isinstance(user, str) or not user.strip() or len(user) > 1024:
                raise ValueError("invalid identity")
            if account is not None and (not isinstance(account, str) or len(account) > 1024):
                raise ValueError("invalid identity")
        key = (adapter or SecurityAdapter()).get_or_create(
            _SERVICE[RUNTIME_PATHS.mode], attended=attended
        )
        if attended:
            cache = _read_cache()
            cache.pop("retry_after", None)
            cache.pop("retry_reason", None)
            _write_cache(cache)
            result = {"status": "ok"}
        else:
            digest = hmac.new(key, _identity_bytes(user, account), hashlib.sha256).hexdigest()
            cache = _read_cache()
            old_generation = cache.get("generation")
            generation = (
                old_generation
                if cache.get("digest") == digest and _valid_uuid(old_generation)
                else str(uuid.uuid4())
            )
            _write_cache({"digest": digest, "generation": generation})
            result = {"status": "ok", "generation": generation}
    except BankedAccessDenied:
        result = {"status": "denied"}
    except Exception:
        result = {"status": "failed"}
    sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")
    return {"ok": 0, "denied": 1, "failed": 2}[result["status"]]


def _valid_uuid(value: object) -> bool:
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except ValueError:
        return False


def _helper_command() -> list[str]:
    # PyInstaller's executable dispatches Gradus arguments directly. A source
    # interpreter must enter the package before it can parse this private flag.
    if getattr(sys, "frozen", False):
        return [sys.executable, "--banked-keychain-helper"]
    return [sys.executable, "-m", "gradus", "--banked-keychain-helper"]


def get_generation(user_id: str, account_id: str | None, *, seconds_remaining: float) -> str | None:
    """Return a generation after a bounded child operation, or Unavailable."""
    if seconds_remaining < 5:
        return None
    cache = _read_cache()
    retry_after = cache.get("retry_after")
    if type(retry_after) in (int, float) and retry_after > time.time():
        return None
    try:
        result = subprocess.run(
            _helper_command(),
            input=json.dumps({"user_id": user_id, "account_id": account_id}).encode(),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
        )
    except subprocess.TimeoutExpired:
        _failure("timeout")
        return None
    except OSError:
        _failure("failed")
        return None
    status = None
    try:
        response = json.loads(result.stdout)
        status = response.get("status")
        generation = response.get("generation")
        if result.returncode == 0 and status == "ok" and _valid_uuid(generation):
            return generation
    except (ValueError, AttributeError, TypeError):
        pass
    _failure("denied" if result.returncode == 1 and status == "denied" else "failed")
    return None


def authorize_access() -> int:
    """Explicit attended action; never called by a background producer."""
    return helper_main(attended=True)
