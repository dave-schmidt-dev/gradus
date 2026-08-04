import React from 'react';
import { Button } from '../core/Button.jsx';

/** Centered empty state: glyph, headline, one-sentence explanation, single fix action. */
export function EmptyState({ glyph = '⌛', title, message, actionLabel, onAction, style }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 'var(--space-6)', padding: 'var(--space-9)', textAlign: 'center', ...style }}>
      <span style={{ display: 'flex', fontSize: 'var(--icon-empty)', lineHeight: 1, color: 'var(--text-muted)' }}>{glyph}</span>
      <span style={{ fontFamily: 'var(--font-sans)', fontSize: 'var(--text-md)', fontWeight: 'var(--weight-semibold)', color: 'var(--text-primary)' }}>{title}</span>
      <span style={{ fontFamily: 'var(--font-sans)', fontSize: 'var(--text-sm)', lineHeight: 'var(--leading-normal)', color: 'var(--text-secondary)', maxWidth: '30ch', textWrap: 'pretty' }}>{message}</span>
      {actionLabel ? <Button variant="prominent" onClick={onAction}>{actionLabel}</Button> : null}
    </div>
  );
}
