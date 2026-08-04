const { UsageBar, Toggle, Button, StatusBadge } = window.ZeroDeltaDesignSystem_9449d1;
const ACC = window.ZeroDeltaDesignSystem_9449d1.PROVIDER_ACCENTS;

/** One compact row: name, worst window's bar + percent, then reset and pace metadata. */
function MenuProviderRow({ provider }) {
  const worst = (provider.windows || []).reduce((a, b) => (a && a.percent <= b.percent ? a : b), null);
  return (
    <div style={{ padding:'var(--space-1) 0', display:'grid', gap:'var(--space-1)' }}>
      <div style={{ display:'flex', alignItems:'center', gap:'var(--space-2)' }}>
        <span style={{ fontFamily:'var(--font-sans)', fontSize:'var(--text-xs)', fontWeight:'var(--weight-semibold)', color:'var(--text-primary)' }}>{provider.name}</span>
        {provider.warning ? <StatusBadge tone="warning" boxed={false}>[!]</StatusBadge> : null}
        {provider.offline ? <StatusBadge tone="offline" boxed={false}>(offline {provider.offline})</StatusBadge> : null}
        <span style={{ marginLeft:'auto', width:'6px', height:'6px', borderRadius:'var(--radius-pill)', background: ACC[provider.name] || 'var(--accent)' }} />
      </div>
      {provider.error ? (
        <span style={{ fontFamily:'var(--font-mono-ui)', fontSize:'var(--text-2xs)', color:'var(--status-critical)' }}>{provider.error}</span>
      ) : (
        <>
          <div style={{ display:'flex', alignItems:'center', gap:'var(--space-4)' }}>
            <span style={{ flex:1 }}><UsageBar percent={worst ? worst.percent : null} variant="capsule" /></span>
            <span style={{ fontFamily:'var(--font-mono-ui)', fontSize:'var(--text-2xs)', color:'var(--text-primary)', width:'34px', textAlign:'right' }}>{worst ? worst.percent + '%' : 'n/a'}</span>
          </div>
          <div style={{ display:'flex', gap:'var(--space-4)', fontFamily:'var(--font-mono-ui)', fontSize:'var(--text-3xs)', color:'var(--text-muted)' }}>
            <span>reset {worst ? worst.reset : 'n/a'}</span>
            <span>{worst ? worst.pace : ''}</span>
          </div>
        </>
      )}
    </div>
  );
}

/** The MenuBarExtra dropdown: 260px, provider rows, two settings toggles, quit. */
function MenuPopover({ providers, sync, setSync, launch, setLaunch, published }) {
  return (
    <div style={{ width:'var(--menu-width)', padding:'var(--space-5)', display:'grid', gap:'var(--space-4)', background:'var(--surface-raised)', border:'var(--border-hair) solid var(--border-hairline)', borderRadius:'var(--radius-lg)', boxShadow:'var(--shadow-menu)' }}>
      <div style={{ display:'flex', alignItems:'baseline', gap:'var(--space-2)' }}>
        <span style={{ fontFamily:'var(--font-sans)', fontSize:'var(--text-base)', fontWeight:'var(--weight-semibold)' }}>Gradus</span>
        <span style={{ marginLeft:'auto', fontFamily:'var(--font-mono-ui)', fontSize:'var(--text-3xs)', color:'var(--text-muted)' }}>{published}</span>
      </div>
      <div style={{ display:'grid' }}>
        {providers.length === 0
          ? <span style={{ fontFamily:'var(--font-sans)', fontSize:'var(--text-xs)', color:'var(--text-muted)' }}>No snapshot data yet</span>
          : providers.map((p) => <MenuProviderRow key={p.name} provider={p} />)}
      </div>
      <span style={{ height:'1px', background:'var(--border-hairline)' }} />
      <div style={{ display:'grid', gap:'var(--space-3)' }}>
        <Toggle label="Enable iCloud Sync" checked={sync} onChange={setSync} />
        <Toggle label="Launch at Login" checked={launch} onChange={setLaunch} />
      </div>
      <span style={{ height:'1px', background:'var(--border-hairline)' }} />
      <Button size="sm" variant="plain" title="Quit the Gradus menu bar app" style={{ justifySelf:'start', padding:'2px 0' }}>Quit Gradus</Button>
    </div>
  );
}

Object.assign(window, { MenuPopover, MenuProviderRow });
