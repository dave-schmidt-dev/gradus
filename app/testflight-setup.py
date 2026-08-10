#!/usr/bin/env python3
"""Compatibility entry point for the attended, assignment-only boundary.

Profile renewal is intentionally separate in ``create-ios-distribution-profile.py``.
This command never creates/deletes groups, testers, certificates, or profiles.
"""

import importlib.util
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "testflight_assign", Path(__file__).with_name("testflight-assign.py")
)
assert _spec and _spec.loader
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)
main = _module.main

if __name__ == "__main__":
    raise SystemExit(main())
