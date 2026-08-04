On/off switch for the product's few settings (iCloud sync, launch at login).

```jsx
<Toggle label="Enable iCloud Sync" checked={sync} onChange={setSync} />
```

- Label left, track right, full row width — settings read as a list.
- Every sync-style toggle is off by default; say so in surrounding copy when it matters.
