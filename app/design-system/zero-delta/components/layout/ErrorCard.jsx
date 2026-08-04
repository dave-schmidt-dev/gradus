import React from 'react';
import { Panel } from './Panel.jsx';

/**
 * Compact single-line failure card. `error` shows a truncated message; `auth` shows the
 * keyboard recovery hint; `stale` is yellow, not red (cached data older than 5 minutes).
 */
export function ErrorCard({ name, tone = 'error', message, fixKey, style }) {
  const color = tone === 'stale' ? 'var(--status-stale)' : 'var(--status-critical)';
  return (
    <Panel title={<span style={{ color, fontWeight: 'var(--weight-bold)' }}>{name}</span>} borderColor={color} padding="8px 12px" style={style}>
      <div style={{ fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-sm)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
        {tone === 'auth' ? (
          <><span style={{ color: 'var(--status-critical)' }}>auth error</span><span style={{ color: 'var(--text-muted)' }}> — press </span><span style={{ color: 'var(--accent-text)' }}>[{fixKey}]</span><span style={{ color: 'var(--text-muted)' }}> to fix</span></>
        ) : tone === 'stale' ? (
          <span style={{ color: 'var(--status-stale)' }}>{message}</span>
        ) : (
          <><span style={{ color: 'var(--status-critical)' }}>error: </span><span style={{ color: 'var(--text-muted)' }}>{message}</span></>
        )}
      </div>
    </Panel>
  );
}
