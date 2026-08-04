import React from 'react';
import { UsageBar, usageColor } from './UsageBar.jsx';
import { PaceIndicator } from './PaceIndicator.jsx';

const cell = { fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-sm)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' };

/**
 * One quota window inside a provider card: label | % | bar | reset | pace.
 * `depleted` collapses to the bar-less "0% until <reset>" layout; `na` shows n/a only.
 */
export function UsageRow({ label, percent = null, reset, pace = 'n/a', state = 'usage', compact = false, cells = 18 }) {
  const tint = usageColor(percent);
  const grid = state === 'depleted'
    ? '32px 40px 1fr'
    : compact ? '32px 40px 1fr 100px' : '32px 40px 1fr 100px 88px';
  const pctText = percent === null || percent === undefined
    ? 'n/a'
    : (percent < 10 ? percent.toFixed(1) : Math.round(percent)) + '%';

  if (state === 'na') {
    return (
      <div style={{ display: 'grid', gridTemplateColumns: grid, gap: 'var(--cell-x)', alignItems: 'center' }}>
        <span style={{ ...cell, color: 'var(--text-muted)' }}>{label}</span>
        <span style={{ ...cell, color: 'var(--text-muted)' }}>n/a</span>
      </div>
    );
  }
  if (state === 'depleted') {
    return (
      <div style={{ display: 'grid', gridTemplateColumns: grid, gap: 'var(--cell-x)', alignItems: 'center' }}>
        <span style={{ ...cell, color: 'var(--text-muted)' }}>{label}</span>
        <span style={{ ...cell, color: 'var(--status-critical)' }}>0%</span>
        <span style={{ ...cell, color: 'var(--status-critical)' }}>until {reset || 'n/a'}</span>
      </div>
    );
  }
  return (
    <div style={{ display: 'grid', gridTemplateColumns: grid, gap: 'var(--cell-x)', alignItems: 'center' }}>
      <span style={{ ...cell, color: 'var(--text-muted)' }}>{label}</span>
      <span style={{ ...cell, color: tint }}>{pctText}</span>
      <UsageBar percent={percent} cells={cells} />
      <span style={{ ...cell, color: 'var(--status-info)' }}>{reset || 'n/a'}</span>
      {compact ? null : <PaceIndicator label={pace} />}
    </div>
  );
}
