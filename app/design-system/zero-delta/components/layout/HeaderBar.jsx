import React from 'react';

const sep = <span style={{ color: 'var(--text-muted)' }}>{'  |  '}</span>;

/** Dashboard header: product name, last-updated stamp, and the refresh countdown. */
export function HeaderBar({ product = 'Gradus', updatedAt, refresh, updating = false, style }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-sm)', whiteSpace: 'pre', ...style }}>
      <span style={{ color: 'var(--accent-text)', fontWeight: 'var(--weight-bold)' }}>{product}</span>
      {sep}
      <span style={{ color: 'var(--text-muted)' }}>Last Updated: </span>
      <span style={{ color: 'var(--status-pace)' }}>{updatedAt}</span>
      {sep}
      {updating
        ? <span style={{ color: 'var(--text-muted)' }}>updating …</span>
        : <><span style={{ color: 'var(--text-muted)' }}>↻ </span><span style={{ color: 'var(--accent-text)' }}>{refresh}</span></>}
    </div>
  );
}
