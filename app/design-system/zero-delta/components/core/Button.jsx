import React from 'react';

const SIZES = {
  sm: { padding: '4px 10px', fontSize: 'var(--text-xs)' },
  md: { padding: '7px 14px', fontSize: 'var(--text-sm)' },
};

/** prominent (accent fill) / bordered (hairline) / plain (text only). */
export function Button({ variant = 'bordered', size = 'md', disabled = false, children, onClick, style, title }) {
  const base = {
    fontFamily: 'var(--font-sans)', fontWeight: 'var(--weight-medium)', lineHeight: 1.2,
    borderRadius: 'var(--radius-sm)', cursor: disabled ? 'default' : 'pointer',
    opacity: disabled ? 0.4 : 1, transition: 'background var(--duration-fast) var(--ease-standard), border-color var(--duration-fast) var(--ease-standard), opacity var(--duration-fast) var(--ease-standard)',
    ...SIZES[size] || SIZES.md,
  };
  const looks = {
    prominent: { background: 'var(--accent)', color: 'var(--accent-contrast)', border: 'var(--border-hair) solid var(--accent)' },
    bordered: { background: 'transparent', color: 'var(--text-primary)', border: 'var(--border-hair) solid var(--border-hairline)' },
    plain: { background: 'transparent', color: 'var(--accent-text)', border: 'var(--border-hair) solid transparent' },
  };
  return (
    <button type="button" title={title} disabled={disabled} onClick={onClick}
      onMouseDown={(e) => { if (!disabled) e.currentTarget.style.opacity = 0.7; }}
      onMouseUp={(e) => { if (!disabled) e.currentTarget.style.opacity = 1; }}
      onMouseLeave={(e) => { if (!disabled) e.currentTarget.style.opacity = 1; }}
      style={{ ...base, ...(looks[variant] || looks.bordered), ...style }}>{children}</button>
  );
}
