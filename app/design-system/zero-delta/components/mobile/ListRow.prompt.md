Grouped-list row for mobile settings and metadata screens.

```jsx
<ListRow title="Enable iCloud Sync" subtitle="off by default, per device" accessory={<Toggle label="iCloud Sync" checked={sync} onChange={setSync} labelsHidden />} />
<ListRow title="Publishing Mac" value="MacBook Pro" chevron onPress={open} isLast />
```

- One trailing element per row: a value, a control, or a chevron — never two controls.
- Rows are 44px minimum; the hairline is full-bleed, not inset.
