import React from 'react';

/** Keyboard hint line: bracketed key in accent, action in body text. */
export function FooterHint({ keys = [{ key: 'q', action: 'quit' }, { key: 'r', action: 'refresh' }], style }) {
  return (
    <div style={{ display: 'flex', gap: 'var(--space-6)', fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-xs)', color: 'var(--text-secondary)', ...style }}>
      {keys.map((k) => (
        <span key={k.key}>
          <span style={{ color: 'var(--accent-text)' }}>[{k.key}]</span> {k.action}
        </span>
      ))}
    </div>
  );
}
