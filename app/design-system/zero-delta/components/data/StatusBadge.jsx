import React from 'react';

const TONES = {
  live: { fg: 'var(--status-ok)', bd: 'var(--status-ok)' },
  cached: { fg: 'var(--status-stale)', bd: 'var(--status-stale)' },
  offline: { fg: 'var(--status-stale)', bd: 'var(--status-stale)' },
  stale: { fg: 'var(--status-stale)', bd: 'var(--status-stale)' },
  warning: { fg: 'var(--status-critical)', bd: 'var(--status-critical)' },
  error: { fg: 'var(--status-critical)', bd: 'var(--status-critical)' },
};

/** Freshness / warning badge as printed in the TUI panel title: live, cached 12m, (offline 3m), [!]. */
export function StatusBadge({ tone = 'live', children, boxed = true }) {
  const t = TONES[tone] || TONES.live;
  return (
    <span style={{
      fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-2xs)', lineHeight: 1,
      color: t.fg, padding: boxed ? '3px 6px' : 0,
      border: boxed ? 'var(--border-hair) solid ' + t.bd : 'none',
      borderRadius: boxed ? 'var(--radius-sm)' : 0, whiteSpace: 'nowrap',
      fontWeight: tone === 'warning' ? 'var(--weight-bold)' : 'var(--weight-regular)',
    }}>{children}</span>
  );
}
