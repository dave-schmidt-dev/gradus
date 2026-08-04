Large-title header for any Zero Delta mobile screen.

```jsx
<MobileNavBar title="Gradus" eyebrow="PUBLISHED 41S AGO" trailing={<Toggle label="iCloud Sync" checked labelsHidden />} />
<MobileNavBar title="Claude" onBack={() => go('now')} backLabel="Now" />
```

- One trailing accessory, never a toolbar of them.
- Title Case title; eyebrow is all-caps mono metadata.
