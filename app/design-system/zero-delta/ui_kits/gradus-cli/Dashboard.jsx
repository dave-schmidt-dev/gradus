const { ProviderCard, HeaderBar, FooterHint, ErrorCard, Panel, UsageRow } = window.ZeroDeltaDesignSystem_9449d1;

/** Two independently measured vertical stacks with a one-cell gutter (ui.py PackedProviderCards). */
function PackedStacks({ cards }) {
  const left = [], right = [];
  let lh = 0, rh = 0;
  cards.forEach((c) => {
    const h = (c.windows ? c.windows.length : 1) + 2;
    if (lh <= rh) { left.push(c); lh += h; } else { right.push(c); rh += h; }
  });
  const render = (c) => c.error
    ? <ErrorCard key={c.name} name={c.name} tone={c.tone} message={c.message} fixKey={c.fixKey} />
    : <ProviderCard key={c.name} {...c} cells={14} />;
  return (
    <div style={{ display:'grid', gridTemplateColumns:'1fr 1fr', gap:'var(--cell-x)', alignItems:'start' }}>
      <div style={{ display:'grid', gap:'var(--cell-y)' }}>{left.map(render)}</div>
      <div style={{ display:'grid', gap:'var(--cell-y)' }}>{right.map(render)}</div>
    </div>
  );
}

/** Depleted providers pair into centered micro cards at the bottom of the grid. */
function MicroDepleted({ cards }) {
  if (!cards.length) return null;
  return (
    <div style={{ display:'grid', gridTemplateColumns:'1fr 1fr', gap:'var(--cell-x)', marginTop:'var(--cell-y)' }}>
      {cards.map((c) => (
        <Panel key={c.name} title={<span style={{ color:'var(--status-critical)', fontWeight:'var(--weight-bold)' }}>{c.name} [!]</span>}
               borderColor="var(--status-critical)" padding="6px 0">
          <div style={{ textAlign:'center', fontFamily:'var(--font-mono-ui)', fontSize:'var(--text-sm)', color:'var(--status-critical)' }}>
            0% until {c.windows[0].reset}
          </div>
        </Panel>
      ))}
    </div>
  );
}

/** Below 79 columns the dashboard drops to one or two lines per provider. */
function CompactLines({ cards }) {
  const arrow = (pace) => pace === 'on pace' ? '=' : pace.startsWith('under +') ? '↑' + pace.slice(7) : pace.startsWith('over -') ? '↓' + pace.slice(6) : '—';
  const tint = (pace) => pace === 'on pace' ? 'var(--status-pace)' : pace.startsWith('under') ? 'var(--status-ok)' : 'var(--status-critical)';
  return (
    <div style={{ display:'grid', gap:'var(--space-2)', fontFamily:'var(--font-mono-ui)', fontSize:'var(--text-sm)' }}>
      {cards.filter((c) => !c.error).map((c) => (
        <div key={c.name} style={{ display:'grid', gap:'2px', paddingBottom:'var(--space-3)' }}>
          {[0, 2].map((start) => {
            const pair = (c.windows || []).slice(start, start + 2);
            if (!pair.length) return null;
            return (
              <div key={start} style={{ display:'grid', gridTemplateColumns:'132px 1fr 1fr', gap:'var(--cell-x)' }}>
                <span style={{ color: start === 0 ? (window.ZeroDeltaDesignSystem_9449d1.PROVIDER_ACCENTS[c.name] || 'var(--accent-text)') : 'transparent', fontWeight:'var(--weight-bold)' }}>{c.name}</span>
                {pair.map((w) => (
                  <span key={w.label} style={{ color: tint(w.pace || 'n/a') }}>{w.label}:{w.percent}% {arrow(w.pace || 'n/a')}</span>
                ))}
              </div>
            );
          })}
        </div>
      ))}
    </div>
  );
}

/** The full terminal dashboard: header, packed cards or compact lines, key hints. */
function CliDashboard({ cards, depleted = [], updatedAt, refresh, updating, narrow, fixKeys = [] }) {
  return (
    <div style={{ display:'grid', gap:'var(--cell-y)' }}>
      <HeaderBar updatedAt={updatedAt} refresh={refresh} updating={updating} />
      {narrow ? <CompactLines cards={cards} /> : <><PackedStacks cards={cards} /><MicroDepleted cards={depleted} /></>}
      <FooterHint keys={[{ key:'q', action:'quit' }, { key:'r', action:'refresh' }, ...fixKeys]} />
    </div>
  );
}

Object.assign(window, { CliDashboard, PackedStacks, CompactLines, MicroDepleted });
