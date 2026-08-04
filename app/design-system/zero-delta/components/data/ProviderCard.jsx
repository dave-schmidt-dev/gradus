import React from 'react';
import { Panel } from '../layout/Panel.jsx';
import { UsageRow } from './UsageRow.jsx';
import { StatusBadge } from './StatusBadge.jsx';

export const PROVIDER_ACCENTS = {
  Codex: 'var(--zd-provider-codex)',
  Claude: 'var(--zd-provider-claude)',
  Antigravity: 'var(--zd-provider-antigravity)',
  Copilot: 'var(--zd-provider-copilot)',
  Cursor: 'var(--zd-provider-cursor)',
  Vibe: 'var(--zd-provider-vibe)',
  'OpenCode Go': 'var(--zd-provider-opencode)',
};

/** One provider's panel: accented title, freshness badge, and one row per quota window. */
export function ProviderCard({ name, windows = [], warning = false, badge, badgeTone = 'live', offline, compact = false, cells = 18, style }) {
  const accent = PROVIDER_ACCENTS[name] || 'var(--accent-text)';
  const title = (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 'var(--space-2)' }}>
      <span style={{ color: accent, fontWeight: 'var(--weight-bold)' }}>{name}</span>
      {warning ? <StatusBadge tone="warning" boxed={false}>[!]</StatusBadge> : null}
      {offline ? <StatusBadge tone="offline" boxed={false}>({offline})</StatusBadge> : null}
    </span>
  );
  return (
    <Panel title={title} borderColor={offline ? 'var(--status-stale)' : accent} subtitle={badge ? <StatusBadge tone={badgeTone}>{badge}</StatusBadge> : null} style={style}>
      <div style={{ display: 'grid', gap: '2px' }}>
        {windows.map((w) => <UsageRow key={w.label} {...w} compact={compact} cells={cells} />)}
      </div>
    </Panel>
  );
}
