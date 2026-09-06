"""One TLS trust source for every provider HTTPS call, in source and frozen mode.

The frozen ``GradusRuntime.app`` is built from the python.org CPython framework,
whose OpenSSL is compiled with an ``OPENSSLDIR`` under
``/Library/Frameworks/Python.framework`` -- a directory that exists only on a
machine that ran python.org's installer. On any other host the interpreter's
default trust store is empty, and every ``urlopen`` fails with
``CERTIFICATE_VERIFY_FAILED``. That is the failure that left the installed
publisher with nothing real to publish (TASKS 2026-09-06).

The fix is deterministic rather than environmental: every provider context is
the interpreter's default context *plus* the pinned ``certifi`` bundle that
ships inside the package. Nothing is exported into the process environment, so
provider child processes (``agy``, ``gh``, ``security``) inherit no trust
override, and the same minimum store applies whether the producer runs from
the checkout or from the bundle.
"""

from __future__ import annotations

import ssl
import sys
from pathlib import Path
from typing import Any

import certifi


def bundled_ca_file() -> Path:
    """Absolute path of the certifi bundle packaged with this runtime."""
    return Path(certifi.where()).resolve()


def default_ssl_context() -> ssl.SSLContext:
    """Return a verifying client context that always includes the bundled CAs.

    Hostname checking and ``CERT_REQUIRED`` come from
    :func:`ssl.create_default_context`; the bundled certifi file is loaded on top
    of whatever the interpreter found on its own, so a host with a working system
    store gains nothing and a host with none gains the pinned bundle.
    """
    context = ssl.create_default_context()
    context.load_verify_locations(cafile=str(bundled_ca_file()))
    return context


def trust_report() -> dict[str, Any]:
    """Credential-free description of the trust store this runtime will use.

    ``interpreter_ca_certificates`` counts what the interpreter loads unaided;
    in the frozen runtime that number is zero, which is the original defect.
    ``ca_certificates`` counts the store providers actually verify against.
    """
    unaided = ssl.create_default_context()
    combined = default_ssl_context()
    paths = ssl.get_default_verify_paths()
    return {
        "bundled_ca_file": str(bundled_ca_file()),
        "ca_certificates": len(combined.get_ca_certs()),
        "check_hostname": combined.check_hostname,
        "frozen": bool(getattr(sys, "frozen", False)),
        "interpreter_ca_certificates": len(unaided.get_ca_certs()),
        "openssl_cafile": paths.openssl_cafile,
        "openssl_capath": paths.openssl_capath,
        "verify_mode": combined.verify_mode.name,
    }
