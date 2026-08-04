Compact failure card — one line, so an unavailable provider costs no vertical space.

```jsx
<ErrorCard name="Cursor" message="state database not found" />
<ErrorCard name="Claude" tone="auth" fixKey="1" />
<ErrorCard name="Vibe" tone="stale" message="stale 7m" />
```

- Stale is yellow and distinct from a hard error; never merge the two.
- Messages are lowercase, no trailing period, truncated with an ellipsis.
