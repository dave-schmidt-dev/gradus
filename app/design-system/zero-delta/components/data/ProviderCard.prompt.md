The primary Gradus surface unit: one provider, one bordered panel, one row per quota window.

```jsx
<ProviderCard
  name="Codex"
  badge="live"
  windows={[
    { label: '5h', percent: 74, reset: '13:16', pace: 'under +38pt' },
    { label: '1w', percent: 85, reset: 'Mar 18 09:00', pace: 'on pace' },
  ]}
/>
```

- Accent comes from the provider name; never recolour a provider.
- `warning` adds `[!]`; `offline="3m"` turns the border yellow and appends `(offline 3m)`.
- Depleted providers collapse to a micro card — pass a single `state="depleted"` window.
