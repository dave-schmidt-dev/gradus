import React from 'react';

/** Pinned Lucide static set — the flagged substitute for SF Symbols on web surfaces. */
export const ICON_CDN = 'https://unpkg.com/lucide-static@0.492.0/icons/';

/** SF Symbol (Swift) -> Lucide name (web). Keep both sides in sync when adding an icon. */
export const SF_TO_LUCIDE = {
  'icloud.slash': 'cloud-off',
  'icloud': 'cloud',
  'wifi.slash': 'wifi-off',
  'hourglass': 'hourglass',
  'person.crop.circle.badge.exclamationmark': 'user-x',
  'exclamationmark.triangle.fill': 'triangle-alert',
  'bell': 'bell',
  'gearshape': 'settings',
  'chevron.right': 'chevron-right',
  'chevron.left': 'chevron-left',
  'arrow.clockwise': 'refresh-cw',
  'clock': 'clock',
  'checkmark.circle': 'circle-check',
  'square.and.arrow.up': 'share',
  'laptopcomputer': 'laptop',
  'iphone': 'smartphone',
  'list.bullet': 'list',
  'info.circle': 'info',
};

const CACHE = {};

/**
 * Chrome icon. The vendor SVG is fetched once and inlined, so it inherits `color`
 * and survives renderers that do not support CSS masks.
 * Data values (percentages, pace, bars) use mono glyphs, not icons.
 */
export function Icon({ name, size = 20, color = 'currentColor', label, style }) {
  const slug = SF_TO_LUCIDE[name] || name;
  const [markup, setMarkup] = React.useState(CACHE[slug] || null);
  React.useEffect(() => {
    if (CACHE[slug]) { setMarkup(CACHE[slug]); return; }
    let alive = true;
    fetch(ICON_CDN + slug + '.svg')
      .then((res) => (res.ok ? res.text() : Promise.reject(res.status)))
      .then((svg) => {
        CACHE[slug] = svg;
        if (alive) setMarkup(svg);
      })
      .catch(() => {});
    return () => { alive = false; };
  }, [slug]);
  return (
    <span role={label ? 'img' : 'presentation'} aria-label={label} aria-hidden={label ? undefined : 'true'} title={label}
      dangerouslySetInnerHTML={markup ? { __html: markup.replace('<svg', '<svg width="' + size + '" height="' + size + '"') } : undefined}
      style={{ display: 'inline-flex', flex: '0 0 auto', width: size + 'px', height: size + 'px', color, lineHeight: 0,
        background: 'none', WebkitMaskImage: 'none', maskImage: 'none', ...style }} />
  );
}

/** 44px tappable icon button — the minimum mobile hit target. */
export function IconButton({ name, size = 20, label, onPress, tone = 'accent', style }) {
  const color = tone === 'accent' ? 'var(--accent-text)' : tone === 'critical' ? 'var(--status-critical)' : 'var(--text-secondary)';
  return (
    <button type="button" onClick={onPress} title={label} aria-label={label}
      style={{ width: '44px', height: '44px', display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
        background: 'none', border: 'none', padding: 0, cursor: 'pointer', color, ...style }}>
      <Icon name={name} size={size} />
    </button>
  );
}
