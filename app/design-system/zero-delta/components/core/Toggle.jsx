import React from 'react';

/** Labelled switch. Label sits left, track right, matching the SwiftUI Toggle rows. */
export function Toggle({ label, checked = false, onChange, disabled = false, labelsHidden = false, style }) {
  return (
    <label title={label} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 'var(--space-4)', fontFamily: 'var(--font-sans)', fontSize: 'var(--text-sm)', color: 'var(--text-primary)', opacity: disabled ? 0.4 : 1, cursor: disabled ? 'default' : 'pointer', ...style }}>
      {labelsHidden ? null : <span>{label}</span>}
      <span onClick={() => { if (!disabled && onChange) onChange(!checked); }}
        style={{ position: 'relative', flex: '0 0 auto', width: 38, height: 22, borderRadius: 'var(--radius-pill)', background: checked ? 'var(--accent)' : 'var(--bar-track)', transition: 'background var(--duration-base) var(--ease-standard)' }}>
        <span style={{ position: 'absolute', top: 2, left: checked ? 18 : 2, width: 18, height: 18, borderRadius: 'var(--radius-pill)', background: 'var(--zd-paper)', boxShadow: '0 1px 2px rgba(0,0,0,.35)', transition: 'left var(--duration-base) var(--ease-standard)' }} />
      </span>
    </label>
  );
}
