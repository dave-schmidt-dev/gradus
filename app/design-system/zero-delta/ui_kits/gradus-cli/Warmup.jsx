const { Panel, HeaderBar, FooterHint } = window.ZeroDeltaDesignSystem_9449d1;

/** Startup screen: spinner, the two reassurance lines, and the standing key hints. */
function WarmupScreen({ updatedAt, elapsed }) {
  const frames = ['⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏'];
  const [i, setI] = React.useState(0);
  React.useEffect(() => {
    const t = setInterval(() => setI((n) => (n + 1) % frames.length), 80);
    return () => clearInterval(t);
  }, []);
  return (
    <div style={{ display:'grid', gap:'var(--cell-y)' }}>
      <HeaderBar updatedAt={updatedAt} refresh={elapsed} />
      <Panel title={<span style={{ color:'var(--accent-text)', fontWeight:'var(--weight-bold)' }}>Warming Up</span>}
             subtitle={<span style={{ fontFamily:'var(--font-mono-ui)', fontSize:'var(--text-2xs)', color:'var(--text-muted)' }}>getting initial usage</span>}>
        <div style={{ fontFamily:'var(--font-mono-ui)', fontSize:'var(--text-sm)', display:'grid', gap:'2px' }}>
          <div><span style={{ color:'var(--accent-text)' }}>{frames[i]}</span> <span style={{ color:'var(--text-primary)' }}>probing 7 providers …</span></div>
          <div style={{ color:'var(--text-muted)' }}>First refresh can take a few seconds.</div>
          <div style={{ color:'var(--text-muted)' }}>Credentials are read locally; nothing is uploaded.</div>
        </div>
      </Panel>
      <FooterHint />
    </div>
  );
}

Object.assign(window, { WarmupScreen });
