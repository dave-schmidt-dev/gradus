# Auth Fix Actions — Design Spec

**Date:** 2026-04-16  
**Status:** Approved  

## Problem

When a provider reports an auth error, the dashboard currently shows the raw error text with no actionable next step. The user has to read the message, figure out the right command or URL, and go fix it manually.

## Goal

When an auth error is detected on a provider card, replace the error display with a short CTA and a numbered key binding. Pressing the key opens either a new Terminal.app window (for CLI auth) or the default browser (for web auth).

## Design

### Auth detection

Pattern-match `snapshot.error` (case-insensitive) against these keywords:

```
"auth", "login", "authenticate", "credentials", "re-authenticate",
"token expired", "sign in", "sign-in"
```

If matched and a fix action exists for that provider name → it's an auth error.

### Fix action table

Defined as `AUTH_ACTIONS: dict[str, tuple[str, str]]` in `__main__.py`:

```python
AUTH_ACTIONS = {
    "Claude": ("cli", "claude login"),
    "Codex": ("cli", "codex login"),
    "Gemini": ("cli", "gemini"),
    "Copilot": ("cli", "gh auth login"),
    "Cursor": ("browser", "https://cursor.sh"),
    "Vibe": ("browser", "https://console.mistral.ai"),
}
```

### Key bindings

Auth-errored providers with a known fix action are numbered `1`–`9` in provider-name alphabetical order (matching dashboard card order). Numbers are assigned dynamically from the current snapshot list each render cycle.

### Card rendering (Option C — approved)

For auth-error snapshots, the error card body is replaced with:

```
auth error — press [N] to fix
```

instead of the raw error text. The red border is kept; the raw error message is dropped from the card body. This keeps the card the same height as today's error card.

### Footer

The footer line gains fix-action hints appended after `[r] refresh`:

```
[q] quit  [r] refresh  [1] fix Gemini  [2] fix Cursor
```

Each hint is only shown when the corresponding provider has an active auth error with a known fix action.

### Launch behavior

**CLI auth** (`kind = "cli"`):
```python
subprocess.Popen(["osascript", "-e", f'tell application "Terminal" to do script "{command}"'])
```
Opens a new Terminal.app window with the command pre-loaded.

**Browser auth** (`kind = "browser"`):
```python
subprocess.Popen(["open", target])
```
Opens the URL in the default browser.

Both are fire-and-forget (`Popen`, not `run`). The dashboard stays live after the action.

### Non-auth errors

Unaffected. If the error doesn't match the auth pattern, or the provider has no entry in `AUTH_ACTIONS`, the card continues to show the raw error text as today.

## Files to change

| File | Change |
|------|--------|
| `ai_monitor/__main__.py` | Add `AUTH_ACTIONS` table, `_is_auth_error()`, `_launch_fix()`, number-key handler in main loop, pass `fix_actions` to `build_dashboard()` |
| `ai_monitor/ui.py` | `build_provider_panel()` — detect auth error flag, render CTA body; `build_dashboard()` — accept `fix_actions` param, render extended footer |

## Out of scope

- Non-macOS terminal launch (Linux/Windows)
- Showing the original error detail on a secondary keypress
- Auto-retry after fix

## Done conditions

- `[N] fix <name>` keys appear in footer only when that provider has an auth error
- Pressing the key opens Terminal (CLI) or browser (web) and dashboard stays running
- Non-auth error cards unchanged
- `pytest tests/ -q` passes, `ruff check ai_monitor/` passes
