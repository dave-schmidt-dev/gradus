# UI kit — Gradus CLI (terminal dashboard)

Recreation of the `python3 -m gradus` live dashboard, built from `gradus/gradus/ui.py` and
`docs/screenshots/dashboard.png`.

## Screens
- **Live dashboard** — header, two packed provider stacks, key hints. Press `r` to refresh
  (header flips to `updating …`), `q` to quit.
- **Warming up** — spinner panel shown until the first probe cycle completes.
- **Auth failure** — Claude collapses to a one-line auth card and a `[1] fix Claude` key appears.
- **Depleted providers** — exhausted providers pair into centered micro cards under the grid.
- **&lt; 79 cols** — the automatic compact layout: 1–2 lines per provider, arrow pace notation,
  exhausted providers dropped entirely.

## Fidelity notes
- Column order, thresholds and wording come from `ui.py`; percentages are always REMAINING.
- Cards are packed into the shorter of two stacks, not laid out row-major (`PackedProviderCards`).
- Real terminal output is monospaced text; this kit reproduces it with the mono UI face and the
  same xterm-256 colors, so a browser rendering matches the terminal closely but not glyph-for-glyph.
