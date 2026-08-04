import React from 'react';

/** Signal ramp from gradus/ui.py _style_for_percent: >=70 green, >=40 yellow, >=20 orange, else red. */
export function usageColor(percent) {
  if (percent === null || percent === undefined || Number.isNaN(percent)) return 'var(--text-muted)';
  if (percent >= 70) return 'var(--status-ok)';
  if (percent >= 40) return 'var(--status-pace)';
  if (percent >= 20) return 'var(--status-low)';
  return 'var(--status-critical)';
}

/**
 * Remaining-capacity bar. `glyph` reproduces the TUI block bar (▓█░, · when unknown);
 * `capsule` reproduces the SwiftUI Capsule track used on Mac/iOS surfaces.
 */
export function UsageBar({ percent = null, variant = 'glyph', cells = 18, height, color, style }) {
  const tint = color || usageColor(percent);
  if (variant === 'glyph') {
    const known = percent !== null && percent !== undefined;
    const filled = known ? Math.max(0, Math.min(cells, Math.round((cells * percent) / 100))) : 0;
    const body = known
      ? (filled > 1 ? '▓'.repeat(filled - 1) : '') + (filled > 0 ? '█' : '')
      : '';
    return (
      <span style={{ fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-sm)', letterSpacing: 0, whiteSpace: 'pre', ...style }}>
        {known ? <span style={{ color: tint }}>{body}</span> : null}
        <span style={{ color: known ? 'var(--bar-empty-glyph)' : 'var(--bar-track)' }}>
          {known ? '░'.repeat(Math.max(0, cells - filled)) : '·'.repeat(cells)}
        </span>
      </span>
    );
  }
  const pct = percent === null || percent === undefined ? 0 : Math.max(0, Math.min(100, percent));
  return (
    <span style={{ display: 'block', width: '100%', height: height || 'var(--bar-height-menu)', borderRadius: 'var(--radius-pill)', background: 'var(--bar-track)', overflow: 'hidden', ...style }}>
      <span style={{ display: 'block', height: '100%', width: pct + '%', borderRadius: 'var(--radius-pill)', background: tint, transition: 'width var(--duration-base) var(--ease-standard)' }} />
    </span>
  );
}
