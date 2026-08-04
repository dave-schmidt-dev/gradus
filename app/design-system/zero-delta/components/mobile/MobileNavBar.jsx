import React from 'react';
import { Icon } from './Icon.jsx';

/** Large-title mobile header. Optional back affordance and one trailing accessory; 44px hit targets. */
export function MobileNavBar({ title, eyebrow, onBack, backLabel = 'Back', trailing, style }) {
  return (
    <div style={{ display: 'grid', gap: 'var(--space-2)', padding: '4px var(--space-6) var(--space-4)', ...style }}>
      {onBack ? (
        <button type="button" onClick={onBack} title={'Go back to ' + backLabel}
          style={{ justifySelf: 'start', minHeight: '44px', display: 'flex', alignItems: 'center', gap: '6px', background: 'none', border: 'none', padding: 0, color: 'var(--accent-text)', fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-sm)', cursor: 'pointer' }}>
          <Icon name="chevron-left" size={18} />{backLabel}
        </button>
      ) : null}
      <div style={{ display: 'flex', alignItems: 'flex-end', gap: 'var(--space-4)' }}>
        <div style={{ display: 'grid', gap: '2px', minWidth: 0 }}>
          {eyebrow ? <span style={{ fontFamily: 'var(--font-mono-ui)', fontSize: 'var(--text-2xs)', letterSpacing: 'var(--tracking-wide)', color: 'var(--text-muted)' }}>{eyebrow}</span> : null}
          <span style={{ fontFamily: 'var(--font-sans)', fontSize: 'var(--text-2xl)', fontWeight: 'var(--weight-bold)', letterSpacing: 'var(--tracking-tight)', lineHeight: 'var(--leading-tight)', color: 'var(--text-primary)' }}>{title}</span>
        </div>
        {trailing ? <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', minHeight: '44px' }}>{trailing}</span> : null}
      </div>
    </div>
  );
}
