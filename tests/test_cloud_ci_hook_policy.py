"""Contract checks for local release validation and authoritative pre-push gate."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

import pytest

ROOT = Path(__file__).parents[1]
HOOK_CONFIG = ROOT / ".pre-commit-config.yaml"
WRAPPER = ROOT / "scripts/pre-push-full-gate.sh"
README = ROOT / "README.md"
TESTING = ROOT / "TESTING.md"


def _hook_block(hook_id: str) -> str:
    """Return the committed config block for one hook id."""
    blocks = HOOK_CONFIG.read_text().split("      - id: ")
    matching = [block for block in blocks[1:] if block.startswith(f"{hook_id}\n")]

    assert len(matching) == 1, f"expected exactly one `{hook_id}` hook"
    return matching[0]


def test_both_local_hook_stages_are_installed() -> None:
    """Fast lint runs at commit; the full gate runs at push."""
    hook_config = HOOK_CONFIG.read_text()

    assert "default_install_hook_types: [pre-commit, pre-push]" in hook_config


def test_push_runs_the_full_gate_hook() -> None:
    """Pre-push is one unconditional serial leg invoking the full gate wrapper."""
    hook_config = HOOK_CONFIG.read_text()
    gate_hook = _hook_block("pre-push-full-gate")

    assert hook_config.count("stages: [pre-push]") == 1
    assert "stages: [pre-push]" in gate_hook
    assert "entry: scripts/pre-push-full-gate.sh" in gate_hook
    # Without both of these the hook would be skipped whenever a push touched no
    # matching file, violating unconditional invocation.
    assert "always_run: true" in gate_hook
    assert "pass_filenames: false" in gate_hook
    assert "require_serial: true" in gate_hook


def test_push_hook_is_installed_on_disk() -> None:
    """A gate that is committed but never installed executes nothing."""
    resolved = subprocess.run(
        ["git", "rev-parse", "--git-path", "hooks"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if resolved.returncode != 0:
        pytest.skip("not a git work tree")

    pre_push = ROOT / resolved.stdout.strip() / "pre-push"

    assert pre_push.exists(), "run `uv run pre-commit install` to install the gate"
    assert "pre-commit" in pre_push.read_text()


def test_push_hook_uses_wrapper_and_not_bare_gate() -> None:
    """The committed hook config invokes the wrapper, not bare app/test-gate.sh."""
    hook_config = HOOK_CONFIG.read_text()

    assert "app/test-gate.sh" not in hook_config
    assert "entry: scripts/pre-push-full-gate.sh" in hook_config


def test_full_gate_wrapper_exists_and_is_executable() -> None:
    """The authoritative pre-push wrapper script must exist and be executable."""
    assert WRAPPER.is_file(), f"expected pre-push full gate script at {WRAPPER}"
    assert os.access(WRAPPER, os.X_OK), f"{WRAPPER} must be executable"


def test_full_gate_wrapper_has_no_outer_ui_lock() -> None:
    """The wrapper must not acquire apple-ui-test-lock or wrap UI legs."""
    if not WRAPPER.is_file():
        pytest.skip(f"{WRAPPER} is absent from this checkout")
    content = WRAPPER.read_text()
    assert "apple-ui-test-lock" not in content
    assert "caffeinate -disu bash app/test-gate.sh" in content


@pytest.fixture
def isolated_gate_env(tmp_path: Path) -> dict[str, Any]:
    """Provide an isolated git repo with fake caffeinate and fake app/test-gate.sh."""
    if not WRAPPER.is_file():
        pytest.skip(f"wrapper script not found at {WRAPPER}")

    repo = tmp_path / "repo"
    repo.mkdir()
    git_env = os.environ.copy()
    git_env["GIT_CONFIG_GLOBAL"] = "/dev/null"

    subprocess.run(
        ["git", "init", "-b", "main"], cwd=repo, env=git_env, check=True, capture_output=True
    )
    subprocess.run(
        ["git", "config", "user.name", "Test Runner"],
        cwd=repo,
        env=git_env,
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "config", "user.email", "test@example.com"],
        cwd=repo,
        env=git_env,
        check=True,
        capture_output=True,
    )

    # Initial commit
    (repo / "tracked.txt").write_text("initial")
    subprocess.run(["git", "add", "."], cwd=repo, env=git_env, check=True, capture_output=True)
    subprocess.run(
        ["git", "commit", "-m", "initial commit"],
        cwd=repo,
        env=git_env,
        check=True,
        capture_output=True,
    )
    base_commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo,
        env=git_env,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()

    # Upstream bare remote
    remote = tmp_path / "remote.git"
    subprocess.run(
        ["git", "clone", "--bare", str(repo), str(remote)],
        env=git_env,
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "remote", "add", "origin", str(remote)],
        cwd=repo,
        env=git_env,
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "fetch", "origin"], cwd=repo, env=git_env, check=True, capture_output=True
    )
    subprocess.run(
        ["git", "branch", "--set-upstream-to=origin/main", "main"],
        cwd=repo,
        env=git_env,
        check=True,
        capture_output=True,
    )

    # Fake app/test-gate.sh
    receipt = tmp_path / "receipt.txt"
    app_dir = repo / "app"
    app_dir.mkdir(parents=True, exist_ok=True)
    gate_script = app_dir / "test-gate.sh"
    gate_script.write_text(
        "#!/usr/bin/env bash\n"
        "set -eu\n"
        'echo "GATE_PROGRESS: started"\n'
        f'echo "GATE_CALLED: GRADUS_STATIC_BASE=${{GRADUS_STATIC_BASE:-<unset>}}" >> "{receipt}"\n'
        'exit "${FAKE_GATE_EXIT:-0}"\n'
    )
    gate_script.chmod(0o755)

    # Fake caffeinate on PATH
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    fake_caffeinate = bin_dir / "caffeinate"
    fake_caffeinate.write_text(
        "#!/usr/bin/env bash\n"
        "set -eu\n"
        f'echo "CAFFEINATE_CALLED: $*" >> "{receipt}"\n'
        "while [[ $# -gt 0 ]]; do\n"
        '  case "$1" in\n'
        "    -*) shift ;;\n"
        "    *) break ;;\n"
        "  esac\n"
        "done\n"
        'exec "$@"\n'
    )
    fake_caffeinate.chmod(0o755)

    # Copy wrapper into repo
    scripts_dir = repo / "scripts"
    scripts_dir.mkdir(parents=True, exist_ok=True)
    wrapper_copy = scripts_dir / "pre-push-full-gate.sh"
    shutil.copy2(WRAPPER, wrapper_copy)
    wrapper_copy.chmod(0o755)

    run_env = git_env.copy()
    run_env["PATH"] = f"{bin_dir}:{run_env.get('PATH', '')}"

    return {
        "repo": repo,
        "receipt": receipt,
        "base_commit": base_commit,
        "wrapper": wrapper_copy,
        "run_env": run_env,
    }


def test_wrapper_preserves_explicit_base(isolated_gate_env: dict[str, Any]) -> None:
    """An explicit GRADUS_STATIC_BASE override is preserved and exported."""
    repo = isolated_gate_env["repo"]
    receipt = isolated_gate_env["receipt"]
    wrapper = isolated_gate_env["wrapper"]
    env = isolated_gate_env["run_env"].copy()
    base_commit = isolated_gate_env["base_commit"]

    # Make a second commit
    (repo / "tracked.txt").write_text("updated")
    subprocess.run(
        ["git", "commit", "-am", "second commit"],
        cwd=repo,
        env=env,
        check=True,
        capture_output=True,
    )

    env["GRADUS_STATIC_BASE"] = base_commit
    res = subprocess.run([str(wrapper)], cwd=repo, env=env, capture_output=True, text=True)

    assert res.returncode == 0, f"wrapper failed:\nSTDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}"
    assert receipt.exists(), "test-gate.sh was not called"
    receipt_text = receipt.read_text()
    assert f"GATE_CALLED: GRADUS_STATIC_BASE={base_commit}" in receipt_text
    assert "CAFFEINATE_CALLED: -disu bash app/test-gate.sh" in receipt_text
    assert "Using explicit GRADUS_STATIC_BASE" in res.stderr or base_commit in res.stderr


def test_wrapper_derives_base_from_upstream_merge_base(isolated_gate_env: dict[str, Any]) -> None:
    """When GRADUS_STATIC_BASE is unset, the upstream merge base is computed and exported."""
    repo = isolated_gate_env["repo"]
    receipt = isolated_gate_env["receipt"]
    wrapper = isolated_gate_env["wrapper"]
    env = isolated_gate_env["run_env"].copy()
    env.pop("GRADUS_STATIC_BASE", None)
    base_commit = isolated_gate_env["base_commit"]

    # Make a second commit on main ahead of origin/main
    (repo / "tracked.txt").write_text("ahead of origin")
    subprocess.run(
        ["git", "commit", "-am", "ahead commit"], cwd=repo, env=env, check=True, capture_output=True
    )

    # Run from a subdirectory to verify repository-root resolution
    res = subprocess.run([str(wrapper)], cwd=repo / "app", env=env, capture_output=True, text=True)

    assert res.returncode == 0, f"wrapper failed:\nSTDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}"
    assert receipt.exists(), "test-gate.sh was not called"
    receipt_text = receipt.read_text()
    assert f"GATE_CALLED: GRADUS_STATIC_BASE={base_commit}" in receipt_text
    assert "CAFFEINATE_CALLED: -disu bash app/test-gate.sh" in receipt_text
    assert res.stderr, "expected progress on stderr"


def test_wrapper_fails_closed_when_no_upstream(isolated_gate_env: dict[str, Any]) -> None:
    """A branch with no upstream configured must fail closed before test-gate."""
    repo = isolated_gate_env["repo"]
    receipt = isolated_gate_env["receipt"]
    wrapper = isolated_gate_env["wrapper"]
    env = isolated_gate_env["run_env"].copy()
    env.pop("GRADUS_STATIC_BASE", None)

    # Checkout new branch without upstream tracking
    subprocess.run(
        ["git", "checkout", "-b", "feature-untracked"],
        cwd=repo,
        env=env,
        check=True,
        capture_output=True,
    )

    res = subprocess.run([str(wrapper)], cwd=repo, env=env, capture_output=True, text=True)

    assert res.returncode != 0, "wrapper should have failed closed"
    assert not receipt.exists() or "GATE_CALLED" not in receipt.read_text()
    assert res.stderr, "expected failure explanation on stderr"


def test_wrapper_fails_closed_when_explicit_base_is_invalid(
    isolated_gate_env: dict[str, Any],
) -> None:
    """An invalid explicit GRADUS_STATIC_BASE must fail closed before test-gate."""
    repo = isolated_gate_env["repo"]
    receipt = isolated_gate_env["receipt"]
    wrapper = isolated_gate_env["wrapper"]
    env = isolated_gate_env["run_env"].copy()
    env["GRADUS_STATIC_BASE"] = "deadbeef_not_a_real_commit_12345"

    res = subprocess.run([str(wrapper)], cwd=repo, env=env, capture_output=True, text=True)

    assert res.returncode != 0, "wrapper should have failed closed"
    assert not receipt.exists() or "GATE_CALLED" not in receipt.read_text()
    assert res.stderr, "expected failure explanation on stderr"


def test_wrapper_fails_closed_when_no_valid_merge_base(
    isolated_gate_env: dict[str, Any],
) -> None:
    """When a branch has an upstream but no common merge base exists, it must fail closed."""
    repo = isolated_gate_env["repo"]
    receipt = isolated_gate_env["receipt"]
    wrapper = isolated_gate_env["wrapper"]
    env = isolated_gate_env["run_env"].copy()
    env.pop("GRADUS_STATIC_BASE", None)

    # Create orphan branch with unrelated history
    subprocess.run(
        ["git", "checkout", "--orphan", "orphan-branch"],
        cwd=repo,
        env=env,
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "orphan commit"],
        cwd=repo,
        env=env,
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "branch", "--set-upstream-to=origin/main", "orphan-branch"],
        cwd=repo,
        env=env,
        check=True,
        capture_output=True,
    )

    res = subprocess.run([str(wrapper)], cwd=repo, env=env, capture_output=True, text=True)

    assert res.returncode != 0, "wrapper should have failed closed"
    assert not receipt.exists() or "GATE_CALLED" not in receipt.read_text()
    assert res.stderr, "expected failure explanation on stderr"


def test_wrapper_prints_progress_to_stderr(isolated_gate_env: dict[str, Any]) -> None:
    """Progress must be emitted to stderr."""
    repo = isolated_gate_env["repo"]
    wrapper = isolated_gate_env["wrapper"]
    env = isolated_gate_env["run_env"].copy()
    base_commit = isolated_gate_env["base_commit"]
    env["GRADUS_STATIC_BASE"] = base_commit

    res = subprocess.run([str(wrapper)], cwd=repo, env=env, capture_output=True, text=True)

    assert res.returncode == 0
    assert res.stderr, "expected progress on stderr"


def test_wrapper_mirrors_gate_output_to_progress_device(
    isolated_gate_env: dict[str, Any], tmp_path: Path
) -> None:
    """Long-running gate output bypasses pre-commit's buffered hook capture."""
    repo = isolated_gate_env["repo"]
    wrapper = isolated_gate_env["wrapper"]
    env = isolated_gate_env["run_env"].copy()
    env["GRADUS_STATIC_BASE"] = isolated_gate_env["base_commit"]
    progress_device = tmp_path / "progress-device.txt"
    progress_device.touch()
    env["GRADUS_PROGRESS_DEVICE"] = str(progress_device)

    res = subprocess.run([str(wrapper)], cwd=repo, env=env, capture_output=True, text=True)

    assert res.returncode == 0
    assert "GATE_PROGRESS: started" in progress_device.read_text()


def test_wrapper_preserves_gate_failure_while_mirroring_progress(
    isolated_gate_env: dict[str, Any], tmp_path: Path
) -> None:
    """Mirroring output must never turn a failing full gate into success."""
    repo = isolated_gate_env["repo"]
    wrapper = isolated_gate_env["wrapper"]
    env = isolated_gate_env["run_env"].copy()
    env["GRADUS_STATIC_BASE"] = isolated_gate_env["base_commit"]
    env["FAKE_GATE_EXIT"] = "23"
    progress_device = tmp_path / "progress-device.txt"
    progress_device.touch()
    env["GRADUS_PROGRESS_DEVICE"] = str(progress_device)

    res = subprocess.run([str(wrapper)], cwd=repo, env=env, capture_output=True, text=True)

    assert res.returncode == 23
    assert "GATE_PROGRESS: started" in progress_device.read_text()


def test_docs_name_candidate_bound_local_app_gate() -> None:
    """Docs must describe the candidate-bound local app validation gate and pre-push full gate."""
    docs = " ".join((README.read_text() + "\n" + TESTING.read_text()).lower().split())

    assert "candidate-bound local gate" in docs
    assert "authoritative local app-validation gate" in docs
    assert "app-specific candidate evidence is collected by the source-bound local" in docs
    assert "xcode cloud validation is optional and non-gating" in docs
    assert "authoritative full gate" in docs or "authoritative full gradus local gate" in docs
    assert "gradus_static_base" in docs
    assert "merge-base" in docs


def test_ios_scheme_includes_widget_tests_for_local_and_optional_hosted_runs() -> None:
    """The shared iOS scheme executes widget tests in every environment."""
    project = (ROOT / "app/project.yml").read_text()
    schemes = project.split("schemes:\n", maxsplit=1)[1]
    ios_scheme = schemes.split("  GradusiOS:\n", maxsplit=1)[1].split(
        "\n  GradusWidget:\n", maxsplit=1
    )[0]
    shared_scheme = (
        ROOT / "app/Gradus.xcodeproj/xcshareddata/xcschemes/GradusiOS.xcscheme"
    ).read_text()

    assert "- GradusWidgetTests" in ios_scheme
    assert 'BuildableName = "GradusWidgetTests.xctest"' in shared_scheme
    assert 'BlueprintName = "GradusWidgetTests"' in shared_scheme
