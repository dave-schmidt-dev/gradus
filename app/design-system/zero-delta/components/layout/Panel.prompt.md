Bordered panel with a title inset into its top edge — the container every Gradus card uses.

```jsx
<Panel title={<span style={{color:'var(--zd-provider-claude)'}}>Claude</span>} subtitle={<StatusBadge>live</StatusBadge>}>
  …rows…
</Panel>
```

- Square corners and a 1px border on terminal surfaces; pass `radius="var(--radius-md)"` for Mac/iOS surfaces.
- No shadows: depth comes from the border plus the surface value step.
