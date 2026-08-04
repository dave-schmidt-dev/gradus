const { MobileNavBar, StatTile, ListRow, Toggle, Button, Shield, EmptyState, UsageBar, StatusBadge, PaceIndicator, Icon, IconButton } = window.ZeroDeltaDesignSystem_9449d1;
const ACC = window.ZeroDeltaDesignSystem_9449d1.PROVIDER_ACCENTS;

const worst = (p) => (p.windows || []).reduce((a, b) => (a && a.percent <= b.percent ? a : b), null);
const rest = (p) => (p.windows || []).filter((w) => w !== worst(p)).map((w) => ({ label: w.label, percent: w.percent }));

/** Screen 1 — Now: one hero tile for the provider closest to depletion, then every provider. */
function NowScreen({ providers, sync, setSync, onOpen, onSettings, published }) {
  const ranked = [...providers].sort((a, b) => (worst(a) ? worst(a).percent : 101) - (worst(b) ? worst(b).percent : 101));
  const [head, ...tail] = ranked;
  const hw = worst(head);
  return (
    <div style={{ display:'grid', gap:'var(--space-5)', padding:'52px 0 40px' }}>
      <MobileNavBar title="Now" eyebrow={published}
        trailing={<IconButton name="settings" label="Open Gradus settings" onPress={onSettings} />} />
      <div style={{ display:'grid', gap:'var(--space-4)', padding:'0 var(--space-6)' }}>
        <StatTile hero title={head.name} dotColor={ACC[head.name]} value={hw.percent} pace={hw.pace}
          warning={head.warning} meta={hw.label + ' window · resets ' + hw.reset + ' · ' + hw.countdown}
          onPress={() => onOpen(head.name)} />
        <span style={{ fontFamily:'var(--font-mono-ui)', fontSize:'var(--text-2xs)', letterSpacing:'var(--tracking-wide)', color:'var(--text-muted)', paddingTop:'var(--space-2)' }}>ALL PROVIDERS</span>
        {tail.map((p) => {
          const w = worst(p);
          return (
            <StatTile key={p.name} title={p.name} dotColor={ACC[p.name]} value={w ? w.percent : null}
              chips={rest(p)} pace={w ? w.pace : undefined} warning={p.warning}
              badge={p.offline ? 'offline ' + p.offline : p.badge === 'live' ? undefined : p.badge}
              badgeTone={p.offline ? 'offline' : 'cached'}
              meta={w ? w.label + ' · resets ' + w.reset : 'no window data'}
              onPress={() => onOpen(p.name)} />
          );
        })}
      </div>
    </div>
  );
}

/** Screen 2 — Provider detail: every window at full size, then provenance. */
function ProviderScreen({ provider, onBack }) {
  return (
    <div style={{ display:'grid', gap:'var(--space-5)', padding:'52px 0 40px' }}>
      <MobileNavBar title={provider.name} eyebrow={provider.offline ? 'OFFLINE ' + provider.offline.toUpperCase() : 'LIVE · API'} onBack={onBack} backLabel="Now"
        trailing={provider.warning ? <StatusBadge tone="warning" boxed={false}>[!]</StatusBadge> : null} />
      <div style={{ display:'grid', gap:'var(--space-4)', padding:'0 var(--space-6)' }}>
        {(provider.windows || []).map((w) => (
          <div key={w.label} style={{ display:'grid', gap:'var(--space-3)', padding:'var(--space-5)', background:'var(--surface-card)', border:'var(--border-hair) solid var(--border-hairline)', borderRadius:'var(--radius-lg)' }}>
            <div style={{ display:'flex', alignItems:'baseline', gap:'var(--space-3)' }}>
              <span style={{ fontFamily:'var(--font-mono-ui)', fontSize:'var(--text-sm)', color:'var(--text-muted)' }}>{w.label}</span>
              <span style={{ fontFamily:'var(--font-sans)', fontSize:'var(--text-sm)', color:'var(--text-secondary)' }}>{w.name}</span>
              <span style={{ marginLeft:'auto' }}><PaceIndicator label={w.pace} /></span>
            </div>
            <div style={{ display:'flex', alignItems:'baseline', gap:'var(--space-2)' }}>
              <span style={{ fontFamily:'var(--font-mono-ui)', fontSize:'var(--text-2xl)', color: w.percent >= 70 ? 'var(--status-ok)' : w.percent >= 40 ? 'var(--status-pace)' : w.percent >= 20 ? 'var(--status-low)' : 'var(--status-critical)' }}>{w.percent}%</span>
              <span style={{ fontFamily:'var(--font-mono-ui)', fontSize:'var(--text-2xs)', color:'var(--text-muted)' }}>remaining</span>
            </div>
            <UsageBar percent={w.percent} variant="capsule" height="var(--bar-height-app)" />
            <div style={{ display:'flex', gap:'var(--space-5)', fontFamily:'var(--font-mono-ui)', fontSize:'var(--text-2xs)', color:'var(--text-muted)' }}>
              <span>resets {w.reset}</span><span>{w.countdown}</span>
            </div>
          </div>
        ))}
        <div style={{ display:'flex', gap:'var(--space-3)', flexWrap:'wrap', paddingTop:'var(--space-2)' }}>
          <Shield label="source" value="api" tone="ok" />
          <Shield label="schema" value="v2" />
          <Shield label="observed" value="41s ago" />
        </div>
      </div>
    </div>
  );
}

/** Screen 3 — Settings: grouped rows, sync off by default, one warning threshold. */
function SettingsScreen({ onBack, sync, setSync, notify, setNotify }) {
  const group = (rows) => (
    <div style={{ background:'var(--surface-card)', border:'var(--border-hair) solid var(--border-hairline)', borderRadius:'var(--radius-lg)', overflow:'hidden' }}>{rows}</div>
  );
  return (
    <div style={{ display:'grid', gap:'var(--space-5)', padding:'52px 0 40px' }}>
      <MobileNavBar title="Settings" onBack={onBack} backLabel="Now" />
      <div style={{ display:'grid', gap:'var(--space-6)', padding:'0 var(--space-6)' }}>
        {group([
          <ListRow key="s" title="iCloud Sync" subtitle="opt-in per device, off by default"
            accessory={<Toggle label="iCloud Sync" checked={sync} onChange={setSync} labelsHidden />} />,
          <ListRow key="n" title="Warning Notifications" subtitle="one banner per window, per crossing"
            accessory={<Toggle label="Warning Notifications" checked={notify} onChange={setNotify} labelsHidden />} isLast />,
        ])}
        {group([
          <ListRow key="t" title="Warning Threshold" value="20%" chevron />,
          <ListRow key="p" title="Publishing Mac" subtitle="last published 41s ago" value="MacBook Pro" chevron isLast />,
        ])}
        {group([
          <ListRow key="pr" title="Providers" value="7 tracked" chevron />,
          <ListRow key="a" title="About Gradus" subtitle="reads a credential-free snapshot only" chevron isLast />,
        ])}
        <div style={{ display:'flex', gap:'var(--space-3)', flexWrap:'wrap' }}>
          <Shield label="gradus" value="ios 0.1" tone="accent" />
          <Shield label="schema" value="v2" />
          <Shield label="credentials" value="never synced" tone="ok" />
        </div>
      </div>
    </div>
  );
}

/** Screen 4 — the three empty states, verbatim from EmptyStateView.swift; SF Symbols map to Lucide. */
function EmptyScreen({ state, onEnableSync }) {
  const COPY = {
    syncDisabled: { sf:'icloud.slash', title:'iCloud Sync Is Off', message:'Turn on iCloud sync to see usage data from your Mac.', actionLabel:'Enable iCloud Sync' },
    notSignedIn: { sf:'person.crop.circle.badge.exclamationmark', title:'Not Signed In to iCloud', message:'Sign in to iCloud in Settings to see usage data from your Mac.', actionLabel:'Open Settings' },
    waiting: { sf:'hourglass', title:'Waiting for First Publish', message:'Sync is on. This fills in once your Mac publishes its first snapshot.' },
  }[state];
  const glyph = <Icon name={COPY.sf} size={44} color="var(--text-muted)" />;
  return (
    <div style={{ display:'grid', gridTemplateRows:'auto 1fr', padding:'52px 0 40px', height:'100%' }}>
      <MobileNavBar title="Now" />
      <div style={{ display:'grid', alignContent:'center' }}>
        <EmptyState glyph={glyph} title={COPY.title} message={COPY.message} actionLabel={COPY.actionLabel} onAction={onEnableSync} />
      </div>
    </div>
  );
}

/** The local notification banner raised when a provider's warning flag flips. */
function WarningBanner({ text, onDismiss }) {
  return (
    <div onClick={onDismiss} title="Dismiss the Gradus warning notification"
      style={{ position:'absolute', top:'56px', left:'12px', right:'12px', zIndex:70, padding:'var(--space-4) var(--space-5)',
        borderRadius:'var(--radius-lg)', background:'rgba(35,35,42,.92)', backdropFilter:'blur(12px)',
        border:'var(--border-hair) solid var(--status-critical)', boxShadow:'var(--shadow-menu)', display:'grid', gap:'2px', cursor:'pointer' }}>
      <div style={{ display:'flex', alignItems:'center', gap:'var(--space-2)' }}>
        <Icon name="triangle-alert" size={14} color="var(--status-critical)" />
        <span style={{ fontFamily:'var(--font-sans)', fontSize:'var(--text-sm)', fontWeight:'var(--weight-semibold)' }}>Gradus</span>
        <span style={{ marginLeft:'auto', fontFamily:'var(--font-mono-ui)', fontSize:'var(--text-3xs)', color:'var(--text-muted)' }}>now</span>
      </div>
      <span style={{ fontFamily:'var(--font-mono-ui)', fontSize:'var(--text-xs)', color:'var(--status-critical)' }}>{text}</span>
    </div>
  );
}

Object.assign(window, { NowScreen, ProviderScreen, SettingsScreen, EmptyScreen, WarningBanner });
