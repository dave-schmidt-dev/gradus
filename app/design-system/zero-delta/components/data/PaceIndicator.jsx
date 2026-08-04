import React from 'react';

const styleFor = (label) => {
  if (label.startsWith('under') || label.startsWith('↑')) return 'var(--status-ok)';
  if (label.startsWith('over') || label.startsWith('↓')) return 'var(--status-critical)';
  if (label === 'on pace' || label === '=') return 'var(--status-pace)';
  return 'var(--text-muted)';
};

/** Compact arrow notation from ui.py _compact_pace. */
export function compactPace(label) {
  if (label === 'n/a') return '—';
  if (label === 'on pace') return '=';
  if (label.startsWith('under +')) return '↑' + label.slice(7);
  if (label.startsWith('over -')) return '↓' + label.slice(6);
  return label;
}

/** Burn-rate label: "under +38pt" / "on pace" / "over -23pt" / "n/a", or its arrow form. */
export function PaceIndicator({ label = 'n/a', compact = false, style }) {
  const text = compact ? compactPace(label) : label;
  return (
    <span style={{ fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-xs)', color: styleFor(text), whiteSpace: 'nowrap', ...style }}>{text}</span>
  );
}
