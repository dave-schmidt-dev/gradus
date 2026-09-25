#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

echo 'banked observation: stdlib codec tests' >&2
PYTHONPATH="$repo_root" python3 -m unittest discover -s tests -p test_banked_observation.py -v
echo 'banked observation: syntax checks' >&2
python3 -m py_compile \
  gradus/banked_observation.py gradus/banked_keychain.py \
  gradus/providers/_base.py gradus/providers/codex.py gradus/providers/claude.py \
  gradus/parsing.py gradus/snapshot.py gradus/__main__.py gradus/paths.py
