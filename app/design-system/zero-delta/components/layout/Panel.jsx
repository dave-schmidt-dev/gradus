import React from 'react';

/**
 * Terminal panel: 1px border with the title inset into the top edge and an optional
 * bottom-left subtitle badge. Square corners on terminal surfaces by design.
 */
export function Panel({ title, subtitle, borderColor = 'var(--border-panel)', radius = 'var(--radius-none)', padding = '10px 12px', children, style }) {
  return (
    <div style={{ position: 'relative', border: 'var(--border-hair) solid ' + borderColor, borderRadius: radius, background: 'var(--surface-card)', padding, ...style }}>
      {title ? (
        <span style={{ position: 'absolute', top: 0, left: 10, transform: 'translateY(-50%)', background: 'var(--surface-card)', padding: '0 6px', fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-sm)', lineHeight: 1 }}>{title}</span>
      ) : null}
      {children}
      {subtitle ? (
        <span style={{ position: 'absolute', bottom: 0, left: 10, transform: 'translateY(50%)', background: 'var(--surface-card)', padding: '0 6px', lineHeight: 1 }}>{subtitle}</span>
      ) : null}
    </div>
  );
}
