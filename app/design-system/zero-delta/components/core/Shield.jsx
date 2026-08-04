import React from 'react';

/** Two-tone shields.io-style badge: dark label block + value block. */
export function Shield({ label, value, tone = 'neutral', style }) {
  const tones = {
    neutral: 'var(--zd-steel)',
    ok: 'var(--status-ok)',
    warn: 'var(--status-pace)',
    critical: 'var(--status-critical)',
    accent: 'var(--accent)',
  };
  const bg = tones[tone] || tones.neutral;
  const cell = { fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-2xs)', lineHeight: 1, padding: '4px 7px', whiteSpace: 'nowrap' };
  return (
    <span style={{ display: 'inline-flex', borderRadius: 'var(--radius-sm)', overflow: 'hidden', ...style }}>
      <span style={{ ...cell, background: 'var(--shield-label-bg)', color: 'var(--shield-label-text)' }}>{label}</span>
      <span style={{ ...cell, background: bg, color: 'var(--zd-terminal-black)', fontWeight: 'var(--weight-semibold)' }}>{value}</span>
    </span>
  );
}
