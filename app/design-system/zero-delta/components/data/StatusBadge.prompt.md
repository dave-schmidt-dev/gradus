Freshness or warning marker that rides in a provider card's title.

```jsx
<StatusBadge tone="live">live</StatusBadge>
<StatusBadge tone="offline">(offline 3m)</StatusBadge>
<StatusBadge tone="warning" boxed={false}>[!]</StatusBadge>
```

- Text is lowercase and literal; keep the product's exact strings.
- `[!]` is always unboxed and red, and always sits immediately after the provider name.
