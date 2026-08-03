# Auth Fix Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** When a provider has an auth error, show a numbered key hint in the card and footer; pressing the key opens Terminal.app (CLI auth) or the browser (web auth).

**Architecture:** New `AUTH_ACTIONS` table and `_is_auth_error()` in `__main__.py` classify errors. A `_build_fix_actions()` helper produces a `dict[str, tuple[str, str, str]]` mapping number keys to `(name, kind, target)` each render cycle. This dict flows to `build_dashboard()` for footer hints and per-panel CTA rendering. `_launch_fix()` fires `osascript`/`open` via `Popen`.

**Tech Stack:** Python 3.10+, Rich (TUI), subprocess (launch), unittest + mock (tests)

**Spec:** `docs/superpowers/specs/2026-04-16-auth-fix-actions-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `ai_monitor/__main__.py` | Modify | `AUTH_ACTIONS`, `_AUTH_KEYWORDS`, `_is_auth_error()`, `_build_fix_actions()`, `_launch_fix()`, number-key handler in main loop, pass `fix_actions` to `build_dashboard()` |
| `ai_monitor/ui.py` | Modify | `build_provider_panel()` accepts `auth_fix_key` param for CTA body; `build_dashboard()` accepts `fix_actions` param for extended footer |
| `tests/test_main.py` | Modify | Tests for `_is_auth_error()`, `_build_fix_actions()`, `_launch_fix()` |
| `tests/test_ui.py` | Modify | Tests for auth-error CTA panel rendering and footer fix hints |

---

### Task 1: Auth Detection — `_is_auth_error()` + Constants

**Files:**
- Modify: `tests/test_main.py` (add new test class at end of file)
- Modify: `ai_monitor/__main__.py:1-38` (add constants and function after imports)

- [x] **Step 1: Write the failing tests**

Add to `tests/test_main.py`:

```python
from ai_monitor.__main__ import _is_auth_error, AUTH_ACTIONS
from ai_monitor.providers import ProviderSnapshot


class IsAuthErrorTests(unittest.TestCase):
    def test_auth_keyword_with_known_provider(self) -> None:
        snap = ProviderSnapshot(
            name="Claude",
            ok=False,
            source="api",
            error="session expired — visit claude.ai to authenticate",
        )
        self.assertTrue(_is_auth_error(snap))

    def test_token_expired_matches(self) -> None:
        snap = ProviderSnapshot(
            name="Codex", ok=False, source="api", error="Token expired, please re-login"
        )
        self.assertTrue(_is_auth_error(snap))

    def test_case_insensitive(self) -> None:
        snap = ProviderSnapshot(
            name="Gemini", ok=False, source="api", error="AUTH FAILED: run gemini to fix"
        )
        self.assertTrue(_is_auth_error(snap))

    def test_non_auth_error_returns_false(self) -> None:
        snap = ProviderSnapshot(name="Claude", ok=False, source="api", error="connection timeout")
        self.assertFalse(_is_auth_error(snap))

    def test_ok_snapshot_returns_false(self) -> None:
        snap = ProviderSnapshot(
            name="Claude", ok=True, source="api", data={"session_percent_left": 50}
        )
        self.assertFalse(_is_auth_error(snap))

    def test_unknown_provider_returns_false(self) -> None:
        snap = ProviderSnapshot(
            name="UnknownAI", ok=False, source="api", error="please authenticate"
        )
        self.assertFalse(_is_auth_error(snap))

    def test_no_error_text_returns_false(self) -> None:
        snap = ProviderSnapshot(name="Claude", ok=False, source="api", error=None)
        self.assertFalse(_is_auth_error(snap))

    def test_all_six_providers_in_auth_actions(self) -> None:
        expected = {"Claude", "Codex", "Gemini", "Copilot", "Cursor", "Vibe"}
        self.assertEqual(set(AUTH_ACTIONS.keys()), expected)
```

- [x] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_main.py::IsAuthErrorTests -v`
Expected: ImportError — `_is_auth_error` and `AUTH_ACTIONS` don't exist yet.

- [x] **Step 3: Implement AUTH_ACTIONS, _AUTH_KEYWORDS, and _is_auth_error()**

Add after the imports block in `ai_monitor/__main__.py` (after line 38, before `parse_args`):

```python
AUTH_ACTIONS: dict[str, tuple[str, str]] = {
    "Claude": ("cli", "claude login"),
    "Codex": ("cli", "codex login"),
    "Gemini": ("cli", "gemini"),
    "Copilot": ("cli", "gh auth login"),
    "Cursor": ("browser", "https://cursor.sh"),
    "Vibe": ("browser", "https://console.mistral.ai"),
}

_AUTH_KEYWORDS = (
    "auth",
    "login",
    "authenticate",
    "credentials",
    "re-authenticate",
    "token expired",
    "sign in",
    "sign-in",
)


def _is_auth_error(snapshot: ProviderSnapshot) -> bool:
    """Return True if the snapshot is an auth error with a known fix action."""
    if snapshot.ok or not snapshot.error:
        return False
    if snapshot.name not in AUTH_ACTIONS:
        return False
    lower = snapshot.error.lower()
    return any(kw in lower for kw in _AUTH_KEYWORDS)
```

- [x] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_main.py::IsAuthErrorTests -v`
Expected: 8 PASSED

- [x] **Step 5: Commit**

```bash
git add ai_monitor/__main__.py tests/test_main.py
git commit -m "feat: add AUTH_ACTIONS table and _is_auth_error() detection"
```

---

### Task 2: Fix Action Mapping — `_build_fix_actions()`

**Files:**
- Modify: `tests/test_main.py` (add new test class)
- Modify: `ai_monitor/__main__.py` (add function after `_is_auth_error`)

- [x] **Step 1: Write the failing tests**

Add to `tests/test_main.py`:

```python
from ai_monitor.__main__ import _build_fix_actions


class BuildFixActionsTests(unittest.TestCase):
    def test_single_auth_error(self) -> None:
        snaps = [
            ProviderSnapshot(name="Gemini", ok=False, source="api", error="auth failed"),
        ]
        actions = _build_fix_actions(snaps)
        self.assertEqual(actions, {"1": ("Gemini", "cli", "gemini")})

    def test_multiple_auth_errors_alphabetical(self) -> None:
        snaps = [
            ProviderSnapshot(name="Gemini", ok=False, source="api", error="auth failed"),
            ProviderSnapshot(name="Claude", ok=False, source="api", error="authenticate required"),
            ProviderSnapshot(
                name="Codex", ok=True, source="api", data={"five_hour_percent_left": 80}
            ),
        ]
        actions = _build_fix_actions(snaps)
        self.assertEqual(actions["1"], ("Claude", "cli", "claude login"))
        self.assertEqual(actions["2"], ("Gemini", "cli", "gemini"))
        self.assertEqual(len(actions), 2)

    def test_no_auth_errors_returns_empty(self) -> None:
        snaps = [
            ProviderSnapshot(
                name="Claude", ok=True, source="api", data={"session_percent_left": 50}
            ),
            ProviderSnapshot(name="Codex", ok=False, source="api", error="connection timeout"),
        ]
        actions = _build_fix_actions(snaps)
        self.assertEqual(actions, {})

    def test_non_auth_error_excluded(self) -> None:
        snaps = [
            ProviderSnapshot(name="Claude", ok=False, source="api", error="rate limited"),
            ProviderSnapshot(name="Gemini", ok=False, source="api", error="sign in required"),
        ]
        actions = _build_fix_actions(snaps)
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions["1"], ("Gemini", "cli", "gemini"))

    def test_browser_action_type(self) -> None:
        snaps = [
            ProviderSnapshot(
                name="Cursor", ok=False, source="api", error="please login to continue"
            ),
        ]
        actions = _build_fix_actions(snaps)
        self.assertEqual(actions["1"], ("Cursor", "browser", "https://cursor.sh"))
```

- [x] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_main.py::BuildFixActionsTests -v`
Expected: ImportError — `_build_fix_actions` doesn't exist yet.

- [x] **Step 3: Implement _build_fix_actions()**

Add after `_is_auth_error()` in `ai_monitor/__main__.py`:

```python
def _build_fix_actions(
    snapshots: list[ProviderSnapshot],
) -> dict[str, tuple[str, str, str]]:
    """Map number keys '1'-'9' to (provider_name, kind, target) for auth-errored providers."""
    auth_errored = sorted(s.name for s in snapshots if _is_auth_error(s))
    actions: dict[str, tuple[str, str, str]] = {}
    for i, name in enumerate(auth_errored[:9], start=1):
        kind, target = AUTH_ACTIONS[name]
        actions[str(i)] = (name, kind, target)
    return actions
```

- [x] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_main.py::BuildFixActionsTests -v`
Expected: 5 PASSED

- [x] **Step 5: Commit**

```bash
git add ai_monitor/__main__.py tests/test_main.py
git commit -m "feat: add _build_fix_actions() to map number keys to auth fixes"
```

---

### Task 3: Launch Behavior — `_launch_fix()`

**Files:**
- Modify: `tests/test_main.py` (add new test class)
- Modify: `ai_monitor/__main__.py` (add function after `_build_fix_actions`)

- [x] **Step 1: Write the failing tests**

Add to `tests/test_main.py`:

```python
from ai_monitor.__main__ import _launch_fix


class LaunchFixTests(unittest.TestCase):
    def test_cli_launches_osascript(self) -> None:
        with patch("ai_monitor.__main__.subprocess.Popen") as mock_popen:
            _launch_fix("cli", "gh auth login")
        mock_popen.assert_called_once()
        args = mock_popen.call_args[0][0]
        self.assertEqual(args[0], "osascript")
        self.assertIn("gh auth login", args[2])

    def test_browser_launches_open(self) -> None:
        with patch("ai_monitor.__main__.subprocess.Popen") as mock_popen:
            _launch_fix("browser", "https://cursor.sh")
        mock_popen.assert_called_once_with(["open", "https://cursor.sh"])

    def test_unknown_kind_is_noop(self) -> None:
        with patch("ai_monitor.__main__.subprocess.Popen") as mock_popen:
            _launch_fix("unknown", "something")
        mock_popen.assert_not_called()
```

- [x] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_main.py::LaunchFixTests -v`
Expected: ImportError — `_launch_fix` doesn't exist yet.

- [x] **Step 3: Implement _launch_fix()**

Add after `_build_fix_actions()` in `ai_monitor/__main__.py`:

```python
def _launch_fix(kind: str, target: str) -> None:
    """Open a Terminal window (CLI) or browser (web) to fix an auth error."""
    if kind == "cli":
        subprocess.Popen(
            [
                "osascript",
                "-e",
                f'tell application "Terminal" to do script "{target}"',
            ]
        )
    elif kind == "browser":
        subprocess.Popen(["open", target])
```

- [x] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_main.py::LaunchFixTests -v`
Expected: 3 PASSED

- [x] **Step 5: Commit**

```bash
git add ai_monitor/__main__.py tests/test_main.py
git commit -m "feat: add _launch_fix() for Terminal/browser auth actions"
```

---

### Task 4: Panel CTA Rendering

**Files:**
- Modify: `tests/test_ui.py` (add new test class)
- Modify: `ai_monitor/ui.py:487-521` (`build_provider_panel` signature + error branch)

- [x] **Step 1: Write the failing tests**

Add to `tests/test_ui.py`:

```python
class AuthFixPanelTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 3, 14, 8, 22, 30)

    def test_auth_error_shows_cta_with_key(self) -> None:
        snap = ProviderSnapshot(
            name="Gemini", ok=False, source="api", error="auth failed: run gemini"
        )
        panel = build_provider_panel(snap, self.now, auth_fix_key="1")
        output = _capture(panel, width=60)
        self.assertIn("auth error", output)
        self.assertIn("[1]", output)
        self.assertIn("to fix", output)
        # Raw error text should NOT appear
        self.assertNotIn("run gemini", output)

    def test_non_auth_error_shows_raw_error(self) -> None:
        snap = ProviderSnapshot(name="Claude", ok=False, source="api", error="connection timeout")
        panel = build_provider_panel(snap, self.now, auth_fix_key=None)
        output = _capture(panel, width=60)
        self.assertIn("error:", output)
        self.assertIn("connection timeout", output)
        self.assertNotIn("to fix", output)

    def test_auth_error_keeps_red_border(self) -> None:
        snap = ProviderSnapshot(name="Claude", ok=False, source="api", error="authenticate failed")
        panel = build_provider_panel(snap, self.now, auth_fix_key="2")
        # Panel border_style is set to "text.red" — verify by checking the Panel object
        self.assertEqual(panel.border_style, "text.red")

    def test_auth_fix_key_none_on_error_shows_normal_error(self) -> None:
        """When auth_fix_key is not passed, error panel is unchanged from current behavior."""
        snap = ProviderSnapshot(name="Codex", ok=False, source="api", error="HTTP 500 server error")
        panel = build_provider_panel(snap, self.now)
        output = _capture(panel, width=60)
        self.assertIn("error:", output)
        self.assertIn("HTTP 500 server error", output)
```

- [x] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_ui.py::AuthFixPanelTests -v`
Expected: TypeError — `build_provider_panel` does not accept `auth_fix_key` parameter yet.

- [x] **Step 3: Add auth_fix_key parameter to build_provider_panel()**

Modify `ai_monitor/ui.py` — change the signature of `build_provider_panel` at line 487:

```python
def build_provider_panel(
    snapshot: ProviderSnapshot, now: datetime, *, threshold: float = 20.0, auth_fix_key: str | None = None,
) -> Panel:
```

Then modify the error branch (lines 513-521). Replace:

```python
    if not snapshot.ok:
        error_msg = _truncate(snapshot.error or "unknown error", 60)
        body = Text.from_markup(f"[text.red]error:[/] [text.muted]{error_msg}[/]")
        return Panel(
            body,
            title=title_text,
            border_style="text.red",
            padding=(0, 1),
        )
```

With:

```python
    if not snapshot.ok:
        if auth_fix_key is not None:
            body = Text.from_markup(
                f"[text.red]auth error[/] [text.muted]— press [/]"
                f"[text.cyan]\\[{auth_fix_key}][/]"
                f"[text.muted] to fix[/]"
            )
        else:
            error_msg = _truncate(snapshot.error or "unknown error", 60)
            body = Text.from_markup(f"[text.red]error:[/] [text.muted]{error_msg}[/]")
        return Panel(
            body,
            title=title_text,
            border_style="text.red",
            padding=(0, 1),
        )
```

Note: The `\\[` is needed because Rich markup uses `[` for style tags — escaping it with `\\[` renders a literal `[`.

- [x] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_ui.py::AuthFixPanelTests -v`
Expected: 4 PASSED

- [x] **Step 5: Verify existing panel tests still pass**

Run: `uv run pytest tests/test_ui.py -v`
Expected: All existing tests PASS (signature change is backwards-compatible via default `auth_fix_key=None`).

- [x] **Step 6: Commit**

```bash
git add ai_monitor/ui.py tests/test_ui.py
git commit -m "feat: render auth-error CTA in provider panel with fix key hint"
```

---

### Task 5: Dashboard Footer with Fix Hints

**Files:**
- Modify: `tests/test_ui.py` (add new test class)
- Modify: `ai_monitor/ui.py:780-833` (`build_dashboard` signature + footer + panel wiring)

- [x] **Step 1: Write the failing tests**

Add to `tests/test_ui.py`:

```python
class AuthFixFooterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 3, 14, 8, 22, 30)

    def test_footer_shows_fix_hints(self) -> None:
        snaps = [
            ProviderSnapshot(name="Gemini", ok=False, source="api", error="auth failed"),
            ProviderSnapshot(
                name="Codex", ok=True, source="api", data={"five_hour_percent_left": 80}
            ),
        ]
        fix_actions = {"1": ("Gemini", "cli", "gemini")}
        dashboard = build_dashboard(snaps, self.now, 30, fix_actions=fix_actions)
        output = _capture(dashboard, width=80)
        self.assertIn("[1]", output)
        self.assertIn("fix Gemini", output)
        # Standard hints still present
        self.assertIn("[q]", output)
        self.assertIn("[r]", output)

    def test_footer_multiple_fix_hints_in_order(self) -> None:
        snaps = [
            ProviderSnapshot(name="Gemini", ok=False, source="api", error="auth failed"),
            ProviderSnapshot(name="Cursor", ok=False, source="api", error="login required"),
        ]
        fix_actions = {
            "1": ("Cursor", "browser", "https://cursor.sh"),
            "2": ("Gemini", "cli", "gemini"),
        }
        dashboard = build_dashboard(snaps, self.now, 30, fix_actions=fix_actions)
        output = _capture(dashboard, width=100)
        self.assertIn("[1]", output)
        self.assertIn("fix Cursor", output)
        self.assertIn("[2]", output)
        self.assertIn("fix Gemini", output)

    def test_footer_no_fix_hints_when_empty(self) -> None:
        snaps = [
            ProviderSnapshot(
                name="Codex", ok=True, source="api", data={"five_hour_percent_left": 80}
            ),
        ]
        dashboard = build_dashboard(snaps, self.now, 30, fix_actions={})
        output = _capture(dashboard, width=80)
        self.assertNotIn("fix", output)

    def test_footer_no_fix_hints_when_none(self) -> None:
        snaps = [
            ProviderSnapshot(
                name="Codex", ok=True, source="api", data={"five_hour_percent_left": 80}
            ),
        ]
        dashboard = build_dashboard(snaps, self.now, 30)
        output = _capture(dashboard, width=80)
        self.assertNotIn("fix", output)

    def test_auth_error_panel_gets_cta_in_dashboard(self) -> None:
        """Verify the panel inside the dashboard shows the CTA, not raw error."""
        snaps = [
            ProviderSnapshot(name="Gemini", ok=False, source="api", error="auth failed"),
        ]
        fix_actions = {"1": ("Gemini", "cli", "gemini")}
        dashboard = build_dashboard(snaps, self.now, 30, fix_actions=fix_actions)
        output = _capture(dashboard, width=80)
        self.assertIn("auth error", output)
        self.assertIn("[1]", output)
        self.assertIn("to fix", output)
        # Raw error should not appear in the panel body
        self.assertNotIn("auth failed", output)
```

- [x] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_ui.py::AuthFixFooterTests -v`
Expected: TypeError — `build_dashboard` does not accept `fix_actions` yet.

- [x] **Step 3: Modify build_dashboard() to accept fix_actions and render footer + panel CTAs**

In `ai_monitor/ui.py`, update the `build_dashboard` signature (line 780) to add `fix_actions`:

```python
def build_dashboard(
    snapshots: list[ProviderSnapshot],
    updated_at: datetime,
    next_refresh_seconds: int,
    *,
    updating: bool = False,
    update_elapsed: float = 0.0,
    threshold: float = 20.0,
    fix_actions: dict[str, tuple[str, str, str]] | None = None,
) -> Group:
```

Then compute per-provider fix keys and pass to panel builder. Replace the panel-building section (lines 806-808):

```python
    _COMPACT = {"Cursor", "Vibe"}
    ordered = sorted(snapshots, key=lambda s: s.name in _COMPACT)
    panels = [build_provider_panel(snap, now, threshold=threshold) for snap in ordered]
```

With:

```python
_COMPACT = {"Cursor", "Vibe"}
ordered = sorted(snapshots, key=lambda s: s.name in _COMPACT)
fix_key_by_name: dict[str, str] = {}
if fix_actions:
    for key, (name, _, _) in fix_actions.items():
        fix_key_by_name[name] = key
panels = [
    build_provider_panel(
        snap,
        now,
        threshold=threshold,
        auth_fix_key=fix_key_by_name.get(snap.name),
    )
    for snap in ordered
]
```

Then update the footer (lines 826-831). Replace:

```python
    footer = Text.assemble(
        ("[q]", "cyan"),
        " quit  ",
        ("[r]", "cyan"),
        " refresh",
    )
```

With:

```python
    footer_parts: list[str | tuple[str, str]] = [
        ("[q]", "cyan"),
        " quit  ",
        ("[r]", "cyan"),
        " refresh",
    ]
    if fix_actions:
        for key in sorted(fix_actions):
            name = fix_actions[key][0]
            footer_parts.extend(["  ", (f"[{key}]", "cyan"), f" fix {name}"])
    footer = Text.assemble(*footer_parts)
```

- [x] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_ui.py::AuthFixFooterTests -v`
Expected: 5 PASSED

- [x] **Step 5: Verify all existing tests still pass**

Run: `uv run pytest tests/ -q`
Expected: All tests pass (70+ existing + new tests).

- [x] **Step 6: Commit**

```bash
git add ai_monitor/ui.py tests/test_ui.py
git commit -m "feat: render auth fix hints in dashboard footer and wire CTA to panels"
```

---

### Task 6: Wire into Main Loop

**Files:**
- Modify: `ai_monitor/__main__.py:335-438` (main loop: compute fix_actions, pass to build_dashboard, handle number keys)

This task modifies the main event loop. No new tests for the key-handler wiring itself — it's deeply coupled to the terminal I/O loop and already covered by the unit tests on the building blocks. The existing `MainOnceTests` in `test_main.py` verify `--once` mode still works.

- [x] **Step 1: Add fix_actions computation and pass to build_dashboard in --once mode**

In `ai_monitor/__main__.py`, update the `--once` code path (around line 335). Replace:

```python
            console.print(build_dashboard(snapshots, updated_at, 0, threshold=threshold))
```

With:

```python
fix_actions = _build_fix_actions(snapshots)
console.print(
    build_dashboard(snapshots, updated_at, 0, threshold=threshold, fix_actions=fix_actions)
)
```

- [x] **Step 2: Add fix_actions to the countdown render loop**

In the main refresh loop, update the countdown phase `build_dashboard` call (around line 376). Replace:

```python
                    while remaining > 0 and not quit_requested:
                        live.update(
                            build_dashboard(
                                current,
                                updated_at,
                                remaining,
                                threshold=threshold,
                            )
                        )
```

With:

```python
                    fix_actions = _build_fix_actions(current)
                    while remaining > 0 and not quit_requested:
                        live.update(
                            build_dashboard(
                                current,
                                updated_at,
                                remaining,
                                threshold=threshold,
                                fix_actions=fix_actions,
                            )
                        )
```

- [x] **Step 3: Add number-key handler in the countdown input handler**

In the countdown input handler (around lines 388-395), after the `r`/`R` check, add the number-key handler. Replace:

```python
                            if readable:
                                key = sys.stdin.read(1)
                                if key in ("q", "Q"):
                                    quit_requested = True
                                    break
                                if key in ("r", "R"):
                                    refresh_now = True
                                    break
```

With:

```python
                            if readable:
                                key = sys.stdin.read(1)
                                if key in ("q", "Q"):
                                    quit_requested = True
                                    break
                                if key in ("r", "R"):
                                    refresh_now = True
                                    break
                                if key in fix_actions:
                                    _, kind, target = fix_actions[key]
                                    _launch_fix(kind, target)
```

- [x] **Step 4: Add fix_actions to the refresh-phase render loop**

In the refresh-phase `build_dashboard` call (around lines 411-419). Replace:

```python
                        while not refresh_future.done():
                            live.update(
                                build_dashboard(
                                    current,
                                    datetime.now(),
                                    0,
                                    updating=True,
                                    update_elapsed=time.monotonic() - refresh_started,
                                    threshold=threshold,
                                )
                            )
```

With:

```python
                        while not refresh_future.done():
                            live.update(
                                build_dashboard(
                                    current,
                                    datetime.now(),
                                    0,
                                    updating=True,
                                    update_elapsed=time.monotonic() - refresh_started,
                                    threshold=threshold,
                                    fix_actions=fix_actions,
                                )
                            )
```

- [x] **Step 5: Run full test suite + linter**

Run: `uv run pytest tests/ -q && ruff check ai_monitor/`
Expected: All tests pass, no ruff errors.

- [x] **Step 6: Commit**

```bash
git add ai_monitor/__main__.py
git commit -m "feat: wire auth fix actions into main loop with number-key dispatch"
```

---

### Task 7: Quality Gate — Full Validation

- [x] **Step 1: Run full test suite**

Run: `uv run pytest tests/ -v`
Expected: All tests pass (70 existing + ~20 new).

- [x] **Step 2: Run ruff**

Run: `ruff check ai_monitor/`
Expected: All checks passed!

- [x] **Step 3: Verify --once mode renders fix hints**

Run: `uv run python -m ai_monitor --once --providers Claude,Gemini 2>&1 | head -30`
Expected: Dashboard renders. If any provider has an auth error, `[N] fix <Name>` should appear in the footer.

- [x] **Step 4: Update TASKS.md**

Add completed task entry:

```
- [x] Auth fix actions: numbered key hints for auth-errored providers, launching Terminal or browser to fix.
```

- [x] **Step 5: Update HISTORY.md**

Add entry for this feature.

- [x] **Step 6: Final commit**

```bash
git add TASKS.md HISTORY.md
git commit -m "docs: add auth fix actions to task list and history"
```
