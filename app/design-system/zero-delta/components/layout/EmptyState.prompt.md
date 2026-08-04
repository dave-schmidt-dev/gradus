Empty state for a surface with no data yet. Write one per cause — never a generic "no data" screen.

```jsx
<EmptyState glyph="☁" title="iCloud Sync Is Off" message="Turn on iCloud sync to see usage data from your Mac." actionLabel="Enable iCloud Sync" />
```

- Title is Title Case; message is one sentence, second person, ends with a period.
- Omit the button when the user can only wait.
