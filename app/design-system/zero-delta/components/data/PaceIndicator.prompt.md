Pace label telling the user whether they are ahead of or behind the expected burn rate for a quota window.

```jsx
<PaceIndicator label="under +38pt" />
<PaceIndicator label="over -23pt" compact />
```

- Exactly four shapes exist: `under +Npt` (green), `on pace` (yellow), `over -Npt` (red), `n/a` (muted). Do not invent new wording.
- `compact` swaps to ↑/=/↓/— for narrow terminal columns.
