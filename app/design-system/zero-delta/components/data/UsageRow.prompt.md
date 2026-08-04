A single quota window inside a provider card — the atomic unit of every Gradus surface.

```jsx
<UsageRow label="5h" percent={74} reset="13:16" pace="under +38pt" />
<UsageRow label="1w" percent={0} reset="Mar 18 09:00" state="depleted" />
```

- Column order is fixed: label, percent, bar, reset, pace. The bar shrinks to nothing before any text is cropped.
- Use `state="depleted"` at exactly 0% and `state="na"` when the upstream API omits the window.
