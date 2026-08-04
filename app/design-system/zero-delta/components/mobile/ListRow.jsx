import React from 'react';
import { Icon } from './Icon.jsx';

/** Grouped-list row: title, optional subtitle, and one trailing value or control. 44px minimum. */
export function ListRow({ title, subtitle, value, accessory, chevron = false, onPress, isLast = false, style }) {
  return (
    <div onClick={onPress} title={onPress ? title : undefined}
      style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-4)', minHeight: '44px',
        padding: 'var(--space-3) var(--space-5)', borderBottom: isLast ? 'none' : 'var(--border-hair) solid var(--border-hairline)',
        cursor: onPress ? 'pointer' : 'default', ...style }}>
      <div style={{ display: 'grid', gap: '2px', minWidth: 0 }}>
        <span style={{ fontFamily: 'var(--font-sans)', fontSize: 'var(--text-sm)', color: 'var(--text-primary)' }}>{title}</span>
        {subtitle ? <span style={{ fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-2xs)', color: 'var(--text-muted)' }}>{subtitle}</span> : null}
      </div>
      <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 'var(--space-3)' }}>
        {value ? <span style={{ fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-xs)', color: 'var(--text-secondary)' }}>{value}</span> : null}
        {accessory}
        {chevron ? <Icon name="chevron-right" size={16} color="var(--text-muted)" /> : null}
      </span>
    </div>
  );
}
