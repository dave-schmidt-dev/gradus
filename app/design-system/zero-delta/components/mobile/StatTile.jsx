import React from 'react';
import { UsageBar, usageColor } from '../data/UsageBar.jsx';
import { PaceIndicator } from '../data/PaceIndicator.jsx';
import { StatusBadge } from '../data/StatusBadge.jsx';
import { Icon } from './Icon.jsx';

/**
 * Full-width mobile tile for one tracked thing: name, big remaining value, capsule bar,
 * per-window chips and a meta line. Tappable when `onPress` is given (44px+ tall).
 */
export function StatTile({ title, dotColor, value, unit = '%', bar, chips = [], meta, pace, badge, badgeTone = 'live', warning, hero = false, onPress, style }) {
  const tint = usageColor(typeof bar === 'number' ? bar : value);
  return (
    <div onClick={onPress} title={onPress ? 'Open ' + title : undefined}
      style={{ display: 'grid', gap: hero ? 'var(--space-5)' : 'var(--space-3)', padding: hero ? 'var(--space-6)' : 'var(--space-5)',
        minHeight: '44px', background: 'var(--surface-card)', border: 'var(--border-hair) solid ' + (hero ? tint : 'var(--border-hairline)'),
        borderRadius: 'var(--radius-lg)', cursor: onPress ? 'pointer' : 'default', ...style }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-2)' }}>
        {dotColor ? <span style={{ width: '8px', height: '8px', borderRadius: 'var(--radius-pill)', background: dotColor, flex: '0 0 auto' }} /> : null}
        <span style={{ fontFamily: 'var(--font-sans)', fontSize: hero ? 'var(--text-md)' : 'var(--text-base)', fontWeight: 'var(--weight-semibold)', color: 'var(--text-primary)' }}>{title}</span>
        {warning ? <StatusBadge tone="warning" boxed={false}>[!]</StatusBadge> : null}
        {badge ? <span style={{ marginLeft: 'auto' }}><StatusBadge tone={badgeTone}>{badge}</StatusBadge></span> : null}
        {onPress && !badge ? <span style={{ marginLeft: 'auto', display: 'flex' }}><Icon name="chevron-right" size={16} color="var(--text-muted)" /></span> : null}
      </div>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 'var(--space-2)' }}>
        <span style={{ fontFamily: 'var(--font-mono-ui)', fontSize: hero ? 'var(--text-3xl)' : 'var(--text-xl)', lineHeight: 'var(--leading-tight)', fontWeight: 'var(--weight-medium)', color: tint }}>
          {value === null || value === undefined ? 'n/a' : value}{value === null || value === undefined ? '' : unit}
        </span>
        <span style={{ fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-2xs)', color: 'var(--text-muted)' }}>remaining</span>
        {pace ? <span style={{ marginLeft: 'auto' }}><PaceIndicator label={pace} /></span> : null}
      </div>
      <UsageBar percent={typeof bar === 'number' ? bar : value} variant="capsule" height="var(--bar-height-app)" />
      {chips.length ? (
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 'var(--space-3)' }}>
          {chips.map((c) => (
            <span key={c.label} style={{ display: 'flex', gap: '6px', alignItems: 'baseline', fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-xs)' }}>
              <span style={{ color: 'var(--text-muted)' }}>{c.label}</span>
              <span style={{ color: usageColor(c.percent) }}>{c.percent === null || c.percent === undefined ? 'n/a' : c.percent + '%'}</span>
            </span>
          ))}
        </div>
      ) : null}
      {meta ? <span style={{ fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-2xs)', color: 'var(--text-muted)' }}>{meta}</span> : null}
    </div>
  );
}
