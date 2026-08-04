Remaining-capacity bar; use it anywhere a quota percentage is shown — glyph inside terminal-style panels, capsule on Mac/iOS surfaces.

```jsx
<UsageBar percent={74} />
<UsageBar percent={12} variant="capsule" height="var(--bar-height-app)" />
```

- Percent is always REMAINING, never used (product invariant).
- Colour comes from `usageColor`: >=70 green, >=40 yellow, >=20 orange, <20 red; `percent={null}` renders the unknown state.
- Never colour a bar by provider accent unless the bar is decorative.
