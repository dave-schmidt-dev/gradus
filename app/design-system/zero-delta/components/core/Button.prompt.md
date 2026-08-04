Action button; use `prominent` for the single fix action on a screen and `bordered` for everything else.

```jsx
<Button variant="prominent" title="Turn on iCloud sync for this Mac">Enable iCloud Sync</Button>
<Button>Quit Gradus</Button>
```

- Labels are Title Case verbs ("Open Settings", "Quit Gradus").
- Press state is a short opacity dip, not a scale or colour change.
- Always give a descriptive `title`; never repeat the label verbatim.
