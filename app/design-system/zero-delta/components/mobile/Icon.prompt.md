Chrome iconography for mobile and web surfaces. Substitutes Lucide for SF Symbols, which Apple does not license for redistribution.

```jsx
<Icon name="cloud-off" size={20} />
<Icon name="icloud.slash" size={24} label="iCloud sync is off" />
<IconButton name="settings" label="Open Gradus settings" onPress={openSettings} />
```

- Icons are for **chrome only** — navigation, settings, notifications, empty states. Data values keep mono glyphs (`↻ ↑ ↓ = ▓ █ ░ [!]`).
- Sizes: 16 inline, 20 default, 24 nav bar, 44 empty-state glyph. Colour is inherited, so wrap in a coloured parent instead of passing a hex.
- In Swift, use the SF Symbol name from `SF_TO_LUCIDE`; the two sides must stay paired.
- Vendor stroke is 2px; the brand would prefer a 1.5px hairline but the vendor files are not rewritten.
