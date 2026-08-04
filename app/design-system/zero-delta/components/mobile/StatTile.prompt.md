The mobile counterpart of ProviderCard: one tile per tracked thing, one headline number each.

```jsx
<StatTile hero title="Claude" dotColor="var(--zd-provider-claude)" value={7} pace="over -23pt"
  meta="5h window · resets 22:00 · in 1h 29m" warning />
<StatTile title="Codex" dotColor="var(--zd-provider-codex)" value={74}
  chips={[{label:'5h',percent:74},{label:'1w',percent:85}]} meta="resets 13:16" onPress={open} />
```

- The headline is the window closest to depletion; other windows become chips.
- Exactly one `hero` tile per screen, always the most urgent provider.
- Colour comes from the signal ramp, not the provider accent — the accent is only the dot.
