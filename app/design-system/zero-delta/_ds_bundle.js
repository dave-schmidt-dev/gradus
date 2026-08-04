/* @ds-bundle: {"format":4,"namespace":"ZeroDeltaDesignSystem_9449d1","components":[{"name":"Button","sourcePath":"components/core/Button.jsx"},{"name":"DeepLink","sourcePath":"components/core/DeepLink.jsx"},{"name":"MiniIcon","sourcePath":"components/core/MiniIcon.jsx"},{"name":"Shield","sourcePath":"components/core/Shield.jsx"},{"name":"Toggle","sourcePath":"components/core/Toggle.jsx"},{"name":"PaceIndicator","sourcePath":"components/data/PaceIndicator.jsx"},{"name":"PROVIDER_ACCENTS","sourcePath":"components/data/ProviderCard.jsx"},{"name":"ProviderCard","sourcePath":"components/data/ProviderCard.jsx"},{"name":"StatusBadge","sourcePath":"components/data/StatusBadge.jsx"},{"name":"UsageBar","sourcePath":"components/data/UsageBar.jsx"},{"name":"UsageRow","sourcePath":"components/data/UsageRow.jsx"},{"name":"EmptyState","sourcePath":"components/layout/EmptyState.jsx"},{"name":"ErrorCard","sourcePath":"components/layout/ErrorCard.jsx"},{"name":"FooterHint","sourcePath":"components/layout/FooterHint.jsx"},{"name":"HeaderBar","sourcePath":"components/layout/HeaderBar.jsx"},{"name":"Panel","sourcePath":"components/layout/Panel.jsx"},{"name":"ICON_CDN","sourcePath":"components/mobile/Icon.jsx"},{"name":"SF_TO_LUCIDE","sourcePath":"components/mobile/Icon.jsx"},{"name":"Icon","sourcePath":"components/mobile/Icon.jsx"},{"name":"IconButton","sourcePath":"components/mobile/Icon.jsx"},{"name":"ListRow","sourcePath":"components/mobile/ListRow.jsx"},{"name":"MobileNavBar","sourcePath":"components/mobile/MobileNavBar.jsx"},{"name":"StatTile","sourcePath":"components/mobile/StatTile.jsx"}],"sourceHashes":{"components/core/Button.jsx":"90165395d2d9","components/core/DeepLink.jsx":"da0fb804a677","components/core/MiniIcon.jsx":"8195156a3ec9","components/core/Shield.jsx":"924c9e850ad2","components/core/Toggle.jsx":"9a4933edef3d","components/data/PaceIndicator.jsx":"3d0ad7fd5415","components/data/ProviderCard.jsx":"715578e6bbb3","components/data/StatusBadge.jsx":"a2673e3e2d9a","components/data/UsageBar.jsx":"665fb0d352b8","components/data/UsageRow.jsx":"ff4d920855ee","components/layout/EmptyState.jsx":"238e2a4698ab","components/layout/ErrorCard.jsx":"57693f2d7e71","components/layout/FooterHint.jsx":"157e1dabb6ab","components/layout/HeaderBar.jsx":"db6bf2181b6d","components/layout/Panel.jsx":"23aa2927d469","components/mobile/Icon.jsx":"15bd0dd98982","components/mobile/ListRow.jsx":"05efb7ca7fce","components/mobile/MobileNavBar.jsx":"7b93151d4df8","components/mobile/StatTile.jsx":"bba123bc2450","ui_kits/gradus-cli/Dashboard.jsx":"48366c3589fd","ui_kits/gradus-cli/Warmup.jsx":"9285f1fc1cca","ui_kits/gradus-mac/MenuPopover.jsx":"cff9ab07bb07","ui_kits/gradus-mobile/Screens.jsx":"c4f48735fe36","ui_kits/gradus-mobile/data.js":"8202d461c5f1","ui_kits/gradus-mobile/ios-frame.jsx":"24642b887be3","ui_kits/providers.js":"3d2de67e4b68"},"inlinedExternals":[],"unexposedExports":[{"name":"compactPace","sourcePath":"components/data/PaceIndicator.jsx"},{"name":"usageColor","sourcePath":"components/data/UsageBar.jsx"}]} */

(() => {

const __ds_ns = (window.ZeroDeltaDesignSystem_9449d1 = window.ZeroDeltaDesignSystem_9449d1 || {});

const __ds_scope = {};

(__ds_ns.__errors = __ds_ns.__errors || []);

// components/core/Button.jsx
try { (() => {
const SIZES = {
  sm: {
    padding: '4px 10px',
    fontSize: 'var(--text-xs)'
  },
  md: {
    padding: '7px 14px',
    fontSize: 'var(--text-sm)'
  }
};

/** prominent (accent fill) / bordered (hairline) / plain (text only). */
function Button({
  variant = 'bordered',
  size = 'md',
  disabled = false,
  children,
  onClick,
  style,
  title
}) {
  const base = {
    fontFamily: 'var(--font-sans)',
    fontWeight: 'var(--weight-medium)',
    lineHeight: 1.2,
    borderRadius: 'var(--radius-sm)',
    cursor: disabled ? 'default' : 'pointer',
    opacity: disabled ? 0.4 : 1,
    transition: 'background var(--duration-fast) var(--ease-standard), border-color var(--duration-fast) var(--ease-standard), opacity var(--duration-fast) var(--ease-standard)',
    ...(SIZES[size] || SIZES.md)
  };
  const looks = {
    prominent: {
      background: 'var(--accent)',
      color: 'var(--accent-contrast)',
      border: 'var(--border-hair) solid var(--accent)'
    },
    bordered: {
      background: 'transparent',
      color: 'var(--text-primary)',
      border: 'var(--border-hair) solid var(--border-hairline)'
    },
    plain: {
      background: 'transparent',
      color: 'var(--accent-text)',
      border: 'var(--border-hair) solid transparent'
    }
  };
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    title: title,
    disabled: disabled,
    onClick: onClick,
    onMouseDown: e => {
      if (!disabled) e.currentTarget.style.opacity = 0.7;
    },
    onMouseUp: e => {
      if (!disabled) e.currentTarget.style.opacity = 1;
    },
    onMouseLeave: e => {
      if (!disabled) e.currentTarget.style.opacity = 1;
    },
    style: {
      ...base,
      ...(looks[variant] || looks.bordered),
      ...style
    }
  }, children);
}
Object.assign(__ds_scope, { Button });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Button.jsx", error: String((e && e.message) || e) }); }

// components/core/DeepLink.jsx
try { (() => {
/** Dashed-underline verification link. The title must state the destination and intent. */
function DeepLink({
  href,
  title,
  children,
  external = true,
  style
}) {
  return /*#__PURE__*/React.createElement("a", {
    href: href,
    title: title,
    target: external ? '_blank' : undefined,
    rel: external ? 'noreferrer' : undefined,
    style: {
      color: 'var(--link)',
      textDecoration: 'underline',
      textDecorationStyle: 'dashed',
      textUnderlineOffset: '3px',
      fontFamily: 'inherit',
      ...style
    },
    onMouseEnter: e => {
      e.currentTarget.style.color = 'var(--link-hover)';
    },
    onMouseLeave: e => {
      e.currentTarget.style.color = 'var(--link)';
    }
  }, children);
}
Object.assign(__ds_scope, { DeepLink });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/DeepLink.jsx", error: String((e && e.message) || e) }); }

// components/core/MiniIcon.jsx
try { (() => {
/**
 * 16/32px proof-of-work icon beside a company, institution or provider name.
 * Uses a local static fallback rather than a remote favicon service.
 */
function MiniIcon({
  src,
  alt,
  title,
  size = 16,
  fallback,
  style
}) {
  const px = size + 'px';
  return /*#__PURE__*/React.createElement("img", {
    src: src,
    alt: alt,
    title: title || alt,
    width: size,
    height: size,
    onError: e => {
      if (fallback && e.currentTarget.src !== fallback) e.currentTarget.src = fallback;
    },
    style: {
      width: px,
      height: px,
      objectFit: 'contain',
      flex: '0 0 auto',
      display: 'inline-block',
      verticalAlign: 'middle',
      ...style
    }
  });
}
Object.assign(__ds_scope, { MiniIcon });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/MiniIcon.jsx", error: String((e && e.message) || e) }); }

// components/core/Shield.jsx
try { (() => {
/** Two-tone shields.io-style badge: dark label block + value block. */
function Shield({
  label,
  value,
  tone = 'neutral',
  style
}) {
  const tones = {
    neutral: 'var(--zd-steel)',
    ok: 'var(--status-ok)',
    warn: 'var(--status-pace)',
    critical: 'var(--status-critical)',
    accent: 'var(--accent)'
  };
  const bg = tones[tone] || tones.neutral;
  const cell = {
    fontFamily: 'var(--font-mono-ui)',
    fontSize: 'var(--text-2xs)',
    lineHeight: 1,
    padding: '4px 7px',
    whiteSpace: 'nowrap'
  };
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      borderRadius: 'var(--radius-sm)',
      overflow: 'hidden',
      ...style
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      ...cell,
      background: 'var(--shield-label-bg)',
      color: 'var(--shield-label-text)'
    }
  }, label), /*#__PURE__*/React.createElement("span", {
    style: {
      ...cell,
      background: bg,
      color: 'var(--zd-terminal-black)',
      fontWeight: 'var(--weight-semibold)'
    }
  }, value));
}
Object.assign(__ds_scope, { Shield });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Shield.jsx", error: String((e && e.message) || e) }); }

// components/core/Toggle.jsx
try { (() => {
/** Labelled switch. Label sits left, track right, matching the SwiftUI Toggle rows. */
function Toggle({
  label,
  checked = false,
  onChange,
  disabled = false,
  labelsHidden = false,
  style
}) {
  return /*#__PURE__*/React.createElement("label", {
    title: label,
    style: {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      gap: 'var(--space-4)',
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--text-sm)',
      color: 'var(--text-primary)',
      opacity: disabled ? 0.4 : 1,
      cursor: disabled ? 'default' : 'pointer',
      ...style
    }
  }, labelsHidden ? null : /*#__PURE__*/React.createElement("span", null, label), /*#__PURE__*/React.createElement("span", {
    onClick: () => {
      if (!disabled && onChange) onChange(!checked);
    },
    style: {
      position: 'relative',
      flex: '0 0 auto',
      width: 38,
      height: 22,
      borderRadius: 'var(--radius-pill)',
      background: checked ? 'var(--accent)' : 'var(--bar-track)',
      transition: 'background var(--duration-base) var(--ease-standard)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'absolute',
      top: 2,
      left: checked ? 18 : 2,
      width: 18,
      height: 18,
      borderRadius: 'var(--radius-pill)',
      background: 'var(--zd-paper)',
      boxShadow: '0 1px 2px rgba(0,0,0,.35)',
      transition: 'left var(--duration-base) var(--ease-standard)'
    }
  })));
}
Object.assign(__ds_scope, { Toggle });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Toggle.jsx", error: String((e && e.message) || e) }); }

// components/data/PaceIndicator.jsx
try { (() => {
const styleFor = label => {
  if (label.startsWith('under') || label.startsWith('↑')) return 'var(--status-ok)';
  if (label.startsWith('over') || label.startsWith('↓')) return 'var(--status-critical)';
  if (label === 'on pace' || label === '=') return 'var(--status-pace)';
  return 'var(--text-muted)';
};

/** Compact arrow notation from ui.py _compact_pace. */
function compactPace(label) {
  if (label === 'n/a') return '—';
  if (label === 'on pace') return '=';
  if (label.startsWith('under +')) return '↑' + label.slice(7);
  if (label.startsWith('over -')) return '↓' + label.slice(6);
  return label;
}

/** Burn-rate label: "under +38pt" / "on pace" / "over -23pt" / "n/a", or its arrow form. */
function PaceIndicator({
  label = 'n/a',
  compact = false,
  style
}) {
  const text = compact ? compactPace(label) : label;
  return /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-xs)',
      color: styleFor(text),
      whiteSpace: 'nowrap',
      ...style
    }
  }, text);
}
Object.assign(__ds_scope, { compactPace, PaceIndicator });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/PaceIndicator.jsx", error: String((e && e.message) || e) }); }

// components/data/StatusBadge.jsx
try { (() => {
const TONES = {
  live: {
    fg: 'var(--status-ok)',
    bd: 'var(--status-ok)'
  },
  cached: {
    fg: 'var(--status-stale)',
    bd: 'var(--status-stale)'
  },
  offline: {
    fg: 'var(--status-stale)',
    bd: 'var(--status-stale)'
  },
  stale: {
    fg: 'var(--status-stale)',
    bd: 'var(--status-stale)'
  },
  warning: {
    fg: 'var(--status-critical)',
    bd: 'var(--status-critical)'
  },
  error: {
    fg: 'var(--status-critical)',
    bd: 'var(--status-critical)'
  }
};

/** Freshness / warning badge as printed in the TUI panel title: live, cached 12m, (offline 3m), [!]. */
function StatusBadge({
  tone = 'live',
  children,
  boxed = true
}) {
  const t = TONES[tone] || TONES.live;
  return /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-2xs)',
      lineHeight: 1,
      color: t.fg,
      padding: boxed ? '3px 6px' : 0,
      border: boxed ? 'var(--border-hair) solid ' + t.bd : 'none',
      borderRadius: boxed ? 'var(--radius-sm)' : 0,
      whiteSpace: 'nowrap',
      fontWeight: tone === 'warning' ? 'var(--weight-bold)' : 'var(--weight-regular)'
    }
  }, children);
}
Object.assign(__ds_scope, { StatusBadge });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/StatusBadge.jsx", error: String((e && e.message) || e) }); }

// components/data/UsageBar.jsx
try { (() => {
/** Signal ramp from gradus/ui.py _style_for_percent: >=70 green, >=40 yellow, >=20 orange, else red. */
function usageColor(percent) {
  if (percent === null || percent === undefined || Number.isNaN(percent)) return 'var(--text-muted)';
  if (percent >= 70) return 'var(--status-ok)';
  if (percent >= 40) return 'var(--status-pace)';
  if (percent >= 20) return 'var(--status-low)';
  return 'var(--status-critical)';
}

/**
 * Remaining-capacity bar. `glyph` reproduces the TUI block bar (▓█░, · when unknown);
 * `capsule` reproduces the SwiftUI Capsule track used on Mac/iOS surfaces.
 */
function UsageBar({
  percent = null,
  variant = 'glyph',
  cells = 18,
  height,
  color,
  style
}) {
  const tint = color || usageColor(percent);
  if (variant === 'glyph') {
    const known = percent !== null && percent !== undefined;
    const filled = known ? Math.max(0, Math.min(cells, Math.round(cells * percent / 100))) : 0;
    const body = known ? (filled > 1 ? '▓'.repeat(filled - 1) : '') + (filled > 0 ? '█' : '') : '';
    return /*#__PURE__*/React.createElement("span", {
      style: {
        fontFamily: 'var(--font-mono-ui)',
        fontSize: 'var(--text-sm)',
        letterSpacing: 0,
        whiteSpace: 'pre',
        ...style
      }
    }, known ? /*#__PURE__*/React.createElement("span", {
      style: {
        color: tint
      }
    }, body) : null, /*#__PURE__*/React.createElement("span", {
      style: {
        color: known ? 'var(--bar-empty-glyph)' : 'var(--bar-track)'
      }
    }, known ? '░'.repeat(Math.max(0, cells - filled)) : '·'.repeat(cells)));
  }
  const pct = percent === null || percent === undefined ? 0 : Math.max(0, Math.min(100, percent));
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'block',
      width: '100%',
      height: height || 'var(--bar-height-menu)',
      borderRadius: 'var(--radius-pill)',
      background: 'var(--bar-track)',
      overflow: 'hidden',
      ...style
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'block',
      height: '100%',
      width: pct + '%',
      borderRadius: 'var(--radius-pill)',
      background: tint,
      transition: 'width var(--duration-base) var(--ease-standard)'
    }
  }));
}
Object.assign(__ds_scope, { usageColor, UsageBar });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/UsageBar.jsx", error: String((e && e.message) || e) }); }

// components/data/UsageRow.jsx
try { (() => {
const cell = {
  fontFamily: 'var(--font-mono-ui)',
  fontSize: 'var(--text-sm)',
  whiteSpace: 'nowrap',
  overflow: 'hidden',
  textOverflow: 'ellipsis'
};

/**
 * One quota window inside a provider card: label | % | bar | reset | pace.
 * `depleted` collapses to the bar-less "0% until <reset>" layout; `na` shows n/a only.
 */
function UsageRow({
  label,
  percent = null,
  reset,
  pace = 'n/a',
  state = 'usage',
  compact = false,
  cells = 18
}) {
  const tint = __ds_scope.usageColor(percent);
  const grid = state === 'depleted' ? '32px 40px 1fr' : compact ? '32px 40px 1fr 100px' : '32px 40px 1fr 100px 88px';
  const pctText = percent === null || percent === undefined ? 'n/a' : (percent < 10 ? percent.toFixed(1) : Math.round(percent)) + '%';
  if (state === 'na') {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        display: 'grid',
        gridTemplateColumns: grid,
        gap: 'var(--cell-x)',
        alignItems: 'center'
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        ...cell,
        color: 'var(--text-muted)'
      }
    }, label), /*#__PURE__*/React.createElement("span", {
      style: {
        ...cell,
        color: 'var(--text-muted)'
      }
    }, "n/a"));
  }
  if (state === 'depleted') {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        display: 'grid',
        gridTemplateColumns: grid,
        gap: 'var(--cell-x)',
        alignItems: 'center'
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        ...cell,
        color: 'var(--text-muted)'
      }
    }, label), /*#__PURE__*/React.createElement("span", {
      style: {
        ...cell,
        color: 'var(--status-critical)'
      }
    }, "0%"), /*#__PURE__*/React.createElement("span", {
      style: {
        ...cell,
        color: 'var(--status-critical)'
      }
    }, "until ", reset || 'n/a'));
  }
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gridTemplateColumns: grid,
      gap: 'var(--cell-x)',
      alignItems: 'center'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      ...cell,
      color: 'var(--text-muted)'
    }
  }, label), /*#__PURE__*/React.createElement("span", {
    style: {
      ...cell,
      color: tint
    }
  }, pctText), /*#__PURE__*/React.createElement(__ds_scope.UsageBar, {
    percent: percent,
    cells: cells
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      ...cell,
      color: 'var(--status-info)'
    }
  }, reset || 'n/a'), compact ? null : /*#__PURE__*/React.createElement(__ds_scope.PaceIndicator, {
    label: pace
  }));
}
Object.assign(__ds_scope, { UsageRow });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/UsageRow.jsx", error: String((e && e.message) || e) }); }

// components/layout/EmptyState.jsx
try { (() => {
/** Centered empty state: glyph, headline, one-sentence explanation, single fix action. */
function EmptyState({
  glyph = '⌛',
  title,
  message,
  actionLabel,
  onAction,
  style
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      gap: 'var(--space-6)',
      padding: 'var(--space-9)',
      textAlign: 'center',
      ...style
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'flex',
      fontSize: 'var(--icon-empty)',
      lineHeight: 1,
      color: 'var(--text-muted)'
    }
  }, glyph), /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--text-md)',
      fontWeight: 'var(--weight-semibold)',
      color: 'var(--text-primary)'
    }
  }, title), /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--text-sm)',
      lineHeight: 'var(--leading-normal)',
      color: 'var(--text-secondary)',
      maxWidth: '30ch',
      textWrap: 'pretty'
    }
  }, message), actionLabel ? /*#__PURE__*/React.createElement(__ds_scope.Button, {
    variant: "prominent",
    onClick: onAction
  }, actionLabel) : null);
}
Object.assign(__ds_scope, { EmptyState });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/layout/EmptyState.jsx", error: String((e && e.message) || e) }); }

// components/layout/FooterHint.jsx
try { (() => {
/** Keyboard hint line: bracketed key in accent, action in body text. */
function FooterHint({
  keys = [{
    key: 'q',
    action: 'quit'
  }, {
    key: 'r',
    action: 'refresh'
  }],
  style
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 'var(--space-6)',
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-xs)',
      color: 'var(--text-secondary)',
      ...style
    }
  }, keys.map(k => /*#__PURE__*/React.createElement("span", {
    key: k.key
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--accent-text)'
    }
  }, "[", k.key, "]"), " ", k.action)));
}
Object.assign(__ds_scope, { FooterHint });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/layout/FooterHint.jsx", error: String((e && e.message) || e) }); }

// components/layout/HeaderBar.jsx
try { (() => {
const sep = /*#__PURE__*/React.createElement("span", {
  style: {
    color: 'var(--text-muted)'
  }
}, '  |  ');

/** Dashboard header: product name, last-updated stamp, and the refresh countdown. */
function HeaderBar({
  product = 'Gradus',
  updatedAt,
  refresh,
  updating = false,
  style
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-sm)',
      whiteSpace: 'pre',
      ...style
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--accent-text)',
      fontWeight: 'var(--weight-bold)'
    }
  }, product), sep, /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--text-muted)'
    }
  }, "Last Updated: "), /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--status-pace)'
    }
  }, updatedAt), sep, updating ? /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--text-muted)'
    }
  }, "updating \u2026") : /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--text-muted)'
    }
  }, "\u21BB "), /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--accent-text)'
    }
  }, refresh)));
}
Object.assign(__ds_scope, { HeaderBar });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/layout/HeaderBar.jsx", error: String((e && e.message) || e) }); }

// components/layout/Panel.jsx
try { (() => {
/**
 * Terminal panel: 1px border with the title inset into the top edge and an optional
 * bottom-left subtitle badge. Square corners on terminal surfaces by design.
 */
function Panel({
  title,
  subtitle,
  borderColor = 'var(--border-panel)',
  radius = 'var(--radius-none)',
  padding = '10px 12px',
  children,
  style
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      border: 'var(--border-hair) solid ' + borderColor,
      borderRadius: radius,
      background: 'var(--surface-card)',
      padding,
      ...style
    }
  }, title ? /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'absolute',
      top: 0,
      left: 10,
      transform: 'translateY(-50%)',
      background: 'var(--surface-card)',
      padding: '0 6px',
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-sm)',
      lineHeight: 1
    }
  }, title) : null, children, subtitle ? /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'absolute',
      bottom: 0,
      left: 10,
      transform: 'translateY(50%)',
      background: 'var(--surface-card)',
      padding: '0 6px',
      lineHeight: 1
    }
  }, subtitle) : null);
}
Object.assign(__ds_scope, { Panel });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/layout/Panel.jsx", error: String((e && e.message) || e) }); }

// components/data/ProviderCard.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
const PROVIDER_ACCENTS = {
  Codex: 'var(--zd-provider-codex)',
  Claude: 'var(--zd-provider-claude)',
  Antigravity: 'var(--zd-provider-antigravity)',
  Copilot: 'var(--zd-provider-copilot)',
  Cursor: 'var(--zd-provider-cursor)',
  Vibe: 'var(--zd-provider-vibe)',
  'OpenCode Go': 'var(--zd-provider-opencode)'
};

/** One provider's panel: accented title, freshness badge, and one row per quota window. */
function ProviderCard({
  name,
  windows = [],
  warning = false,
  badge,
  badgeTone = 'live',
  offline,
  compact = false,
  cells = 18,
  style
}) {
  const accent = PROVIDER_ACCENTS[name] || 'var(--accent-text)';
  const title = /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: 'var(--space-2)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      color: accent,
      fontWeight: 'var(--weight-bold)'
    }
  }, name), warning ? /*#__PURE__*/React.createElement(__ds_scope.StatusBadge, {
    tone: "warning",
    boxed: false
  }, "[!]") : null, offline ? /*#__PURE__*/React.createElement(__ds_scope.StatusBadge, {
    tone: "offline",
    boxed: false
  }, "(", offline, ")") : null);
  return /*#__PURE__*/React.createElement(__ds_scope.Panel, {
    title: title,
    borderColor: offline ? 'var(--status-stale)' : accent,
    subtitle: badge ? /*#__PURE__*/React.createElement(__ds_scope.StatusBadge, {
      tone: badgeTone
    }, badge) : null,
    style: style
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: '2px'
    }
  }, windows.map(w => /*#__PURE__*/React.createElement(__ds_scope.UsageRow, _extends({
    key: w.label
  }, w, {
    compact: compact,
    cells: cells
  })))));
}
Object.assign(__ds_scope, { PROVIDER_ACCENTS, ProviderCard });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/ProviderCard.jsx", error: String((e && e.message) || e) }); }

// components/layout/ErrorCard.jsx
try { (() => {
/**
 * Compact single-line failure card. `error` shows a truncated message; `auth` shows the
 * keyboard recovery hint; `stale` is yellow, not red (cached data older than 5 minutes).
 */
function ErrorCard({
  name,
  tone = 'error',
  message,
  fixKey,
  style
}) {
  const color = tone === 'stale' ? 'var(--status-stale)' : 'var(--status-critical)';
  return /*#__PURE__*/React.createElement(__ds_scope.Panel, {
    title: /*#__PURE__*/React.createElement("span", {
      style: {
        color,
        fontWeight: 'var(--weight-bold)'
      }
    }, name),
    borderColor: color,
    padding: "8px 12px",
    style: style
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-sm)',
      whiteSpace: 'nowrap',
      overflow: 'hidden',
      textOverflow: 'ellipsis'
    }
  }, tone === 'auth' ? /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--status-critical)'
    }
  }, "auth error"), /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--text-muted)'
    }
  }, " \u2014 press "), /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--accent-text)'
    }
  }, "[", fixKey, "]"), /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--text-muted)'
    }
  }, " to fix")) : tone === 'stale' ? /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--status-stale)'
    }
  }, message) : /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--status-critical)'
    }
  }, "error: "), /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--text-muted)'
    }
  }, message))));
}
Object.assign(__ds_scope, { ErrorCard });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/layout/ErrorCard.jsx", error: String((e && e.message) || e) }); }

// components/mobile/Icon.jsx
try { (() => {
/** Pinned Lucide static set — the flagged substitute for SF Symbols on web surfaces. */
const ICON_CDN = 'https://unpkg.com/lucide-static@0.492.0/icons/';

/** SF Symbol (Swift) -> Lucide name (web). Keep both sides in sync when adding an icon. */
const SF_TO_LUCIDE = {
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
  'info.circle': 'info'
};
const CACHE = {};

/**
 * Chrome icon. The vendor SVG is fetched once and inlined, so it inherits `color`
 * and survives renderers that do not support CSS masks.
 * Data values (percentages, pace, bars) use mono glyphs, not icons.
 */
function Icon({
  name,
  size = 20,
  color = 'currentColor',
  label,
  style
}) {
  const slug = SF_TO_LUCIDE[name] || name;
  const [markup, setMarkup] = React.useState(CACHE[slug] || null);
  React.useEffect(() => {
    if (CACHE[slug]) {
      setMarkup(CACHE[slug]);
      return;
    }
    let alive = true;
    fetch(ICON_CDN + slug + '.svg').then(res => res.ok ? res.text() : Promise.reject(res.status)).then(svg => {
      CACHE[slug] = svg;
      if (alive) setMarkup(svg);
    }).catch(() => {});
    return () => {
      alive = false;
    };
  }, [slug]);
  return /*#__PURE__*/React.createElement("span", {
    role: label ? 'img' : 'presentation',
    "aria-label": label,
    "aria-hidden": label ? undefined : 'true',
    title: label,
    dangerouslySetInnerHTML: markup ? {
      __html: markup.replace('<svg', '<svg width="' + size + '" height="' + size + '"')
    } : undefined,
    style: {
      display: 'inline-flex',
      flex: '0 0 auto',
      width: size + 'px',
      height: size + 'px',
      color,
      lineHeight: 0,
      background: 'none',
      WebkitMaskImage: 'none',
      maskImage: 'none',
      ...style
    }
  });
}

/** 44px tappable icon button — the minimum mobile hit target. */
function IconButton({
  name,
  size = 20,
  label,
  onPress,
  tone = 'accent',
  style
}) {
  const color = tone === 'accent' ? 'var(--accent-text)' : tone === 'critical' ? 'var(--status-critical)' : 'var(--text-secondary)';
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    onClick: onPress,
    title: label,
    "aria-label": label,
    style: {
      width: '44px',
      height: '44px',
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      background: 'none',
      border: 'none',
      padding: 0,
      cursor: 'pointer',
      color,
      ...style
    }
  }, /*#__PURE__*/React.createElement(Icon, {
    name: name,
    size: size
  }));
}
Object.assign(__ds_scope, { ICON_CDN, SF_TO_LUCIDE, Icon, IconButton });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/mobile/Icon.jsx", error: String((e && e.message) || e) }); }

// components/mobile/ListRow.jsx
try { (() => {
/** Grouped-list row: title, optional subtitle, and one trailing value or control. 44px minimum. */
function ListRow({
  title,
  subtitle,
  value,
  accessory,
  chevron = false,
  onPress,
  isLast = false,
  style
}) {
  return /*#__PURE__*/React.createElement("div", {
    onClick: onPress,
    title: onPress ? title : undefined,
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 'var(--space-4)',
      minHeight: '44px',
      padding: 'var(--space-3) var(--space-5)',
      borderBottom: isLast ? 'none' : 'var(--border-hair) solid var(--border-hairline)',
      cursor: onPress ? 'pointer' : 'default',
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: '2px',
      minWidth: 0
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--text-sm)',
      color: 'var(--text-primary)'
    }
  }, title), subtitle ? /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-2xs)',
      color: 'var(--text-muted)'
    }
  }, subtitle) : null), /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto',
      display: 'flex',
      alignItems: 'center',
      gap: 'var(--space-3)'
    }
  }, value ? /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-xs)',
      color: 'var(--text-secondary)'
    }
  }, value) : null, accessory, chevron ? /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: "chevron-right",
    size: 16,
    color: "var(--text-muted)"
  }) : null));
}
Object.assign(__ds_scope, { ListRow });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/mobile/ListRow.jsx", error: String((e && e.message) || e) }); }

// components/mobile/MobileNavBar.jsx
try { (() => {
/** Large-title mobile header. Optional back affordance and one trailing accessory; 44px hit targets. */
function MobileNavBar({
  title,
  eyebrow,
  onBack,
  backLabel = 'Back',
  trailing,
  style
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: 'var(--space-2)',
      padding: '4px var(--space-6) var(--space-4)',
      ...style
    }
  }, onBack ? /*#__PURE__*/React.createElement("button", {
    type: "button",
    onClick: onBack,
    title: 'Go back to ' + backLabel,
    style: {
      justifySelf: 'start',
      minHeight: '44px',
      display: 'flex',
      alignItems: 'center',
      gap: '6px',
      background: 'none',
      border: 'none',
      padding: 0,
      color: 'var(--accent-text)',
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-sm)',
      cursor: 'pointer'
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: "chevron-left",
    size: 18
  }), backLabel) : null, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'flex-end',
      gap: 'var(--space-4)'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: '2px',
      minWidth: 0
    }
  }, eyebrow ? /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-2xs)',
      letterSpacing: 'var(--tracking-wide)',
      color: 'var(--text-muted)'
    }
  }, eyebrow) : null, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--text-2xl)',
      fontWeight: 'var(--weight-bold)',
      letterSpacing: 'var(--tracking-tight)',
      lineHeight: 'var(--leading-tight)',
      color: 'var(--text-primary)'
    }
  }, title)), trailing ? /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto',
      display: 'flex',
      alignItems: 'center',
      minHeight: '44px'
    }
  }, trailing) : null));
}
Object.assign(__ds_scope, { MobileNavBar });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/mobile/MobileNavBar.jsx", error: String((e && e.message) || e) }); }

// components/mobile/StatTile.jsx
try { (() => {
/**
 * Full-width mobile tile for one tracked thing: name, big remaining value, capsule bar,
 * per-window chips and a meta line. Tappable when `onPress` is given (44px+ tall).
 */
function StatTile({
  title,
  dotColor,
  value,
  unit = '%',
  bar,
  chips = [],
  meta,
  pace,
  badge,
  badgeTone = 'live',
  warning,
  hero = false,
  onPress,
  style
}) {
  const tint = __ds_scope.usageColor(typeof bar === 'number' ? bar : value);
  return /*#__PURE__*/React.createElement("div", {
    onClick: onPress,
    title: onPress ? 'Open ' + title : undefined,
    style: {
      display: 'grid',
      gap: hero ? 'var(--space-5)' : 'var(--space-3)',
      padding: hero ? 'var(--space-6)' : 'var(--space-5)',
      minHeight: '44px',
      background: 'var(--surface-card)',
      border: 'var(--border-hair) solid ' + (hero ? tint : 'var(--border-hairline)'),
      borderRadius: 'var(--radius-lg)',
      cursor: onPress ? 'pointer' : 'default',
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 'var(--space-2)'
    }
  }, dotColor ? /*#__PURE__*/React.createElement("span", {
    style: {
      width: '8px',
      height: '8px',
      borderRadius: 'var(--radius-pill)',
      background: dotColor,
      flex: '0 0 auto'
    }
  }) : null, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-sans)',
      fontSize: hero ? 'var(--text-md)' : 'var(--text-base)',
      fontWeight: 'var(--weight-semibold)',
      color: 'var(--text-primary)'
    }
  }, title), warning ? /*#__PURE__*/React.createElement(__ds_scope.StatusBadge, {
    tone: "warning",
    boxed: false
  }, "[!]") : null, badge ? /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto'
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.StatusBadge, {
    tone: badgeTone
  }, badge)) : null, onPress && !badge ? /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto',
      display: 'flex'
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: "chevron-right",
    size: 16,
    color: "var(--text-muted)"
  })) : null), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'baseline',
      gap: 'var(--space-2)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: hero ? 'var(--text-3xl)' : 'var(--text-xl)',
      lineHeight: 'var(--leading-tight)',
      fontWeight: 'var(--weight-medium)',
      color: tint
    }
  }, value === null || value === undefined ? 'n/a' : value, value === null || value === undefined ? '' : unit), /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-2xs)',
      color: 'var(--text-muted)'
    }
  }, "remaining"), pace ? /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto'
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.PaceIndicator, {
    label: pace
  })) : null), /*#__PURE__*/React.createElement(__ds_scope.UsageBar, {
    percent: typeof bar === 'number' ? bar : value,
    variant: "capsule",
    height: "var(--bar-height-app)"
  }), chips.length ? /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexWrap: 'wrap',
      gap: 'var(--space-3)'
    }
  }, chips.map(c => /*#__PURE__*/React.createElement("span", {
    key: c.label,
    style: {
      display: 'flex',
      gap: '6px',
      alignItems: 'baseline',
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-xs)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--text-muted)'
    }
  }, c.label), /*#__PURE__*/React.createElement("span", {
    style: {
      color: __ds_scope.usageColor(c.percent)
    }
  }, c.percent === null || c.percent === undefined ? 'n/a' : c.percent + '%')))) : null, meta ? /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-2xs)',
      color: 'var(--text-muted)'
    }
  }, meta) : null);
}
Object.assign(__ds_scope, { StatTile });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/mobile/StatTile.jsx", error: String((e && e.message) || e) }); }

// ui_kits/gradus-cli/Dashboard.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
const {
  ProviderCard,
  HeaderBar,
  FooterHint,
  ErrorCard,
  Panel,
  UsageRow
} = window.ZeroDeltaDesignSystem_9449d1;

/** Two independently measured vertical stacks with a one-cell gutter (ui.py PackedProviderCards). */
function PackedStacks({
  cards
}) {
  const left = [],
    right = [];
  let lh = 0,
    rh = 0;
  cards.forEach(c => {
    const h = (c.windows ? c.windows.length : 1) + 2;
    if (lh <= rh) {
      left.push(c);
      lh += h;
    } else {
      right.push(c);
      rh += h;
    }
  });
  const render = c => c.error ? /*#__PURE__*/React.createElement(ErrorCard, {
    key: c.name,
    name: c.name,
    tone: c.tone,
    message: c.message,
    fixKey: c.fixKey
  }) : /*#__PURE__*/React.createElement(ProviderCard, _extends({
    key: c.name
  }, c, {
    cells: 14
  }));
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gridTemplateColumns: '1fr 1fr',
      gap: 'var(--cell-x)',
      alignItems: 'start'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: 'var(--cell-y)'
    }
  }, left.map(render)), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: 'var(--cell-y)'
    }
  }, right.map(render)));
}

/** Depleted providers pair into centered micro cards at the bottom of the grid. */
function MicroDepleted({
  cards
}) {
  if (!cards.length) return null;
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gridTemplateColumns: '1fr 1fr',
      gap: 'var(--cell-x)',
      marginTop: 'var(--cell-y)'
    }
  }, cards.map(c => /*#__PURE__*/React.createElement(Panel, {
    key: c.name,
    title: /*#__PURE__*/React.createElement("span", {
      style: {
        color: 'var(--status-critical)',
        fontWeight: 'var(--weight-bold)'
      }
    }, c.name, " [!]"),
    borderColor: "var(--status-critical)",
    padding: "6px 0"
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      textAlign: 'center',
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-sm)',
      color: 'var(--status-critical)'
    }
  }, "0% until ", c.windows[0].reset))));
}

/** Below 79 columns the dashboard drops to one or two lines per provider. */
function CompactLines({
  cards
}) {
  const arrow = pace => pace === 'on pace' ? '=' : pace.startsWith('under +') ? '↑' + pace.slice(7) : pace.startsWith('over -') ? '↓' + pace.slice(6) : '—';
  const tint = pace => pace === 'on pace' ? 'var(--status-pace)' : pace.startsWith('under') ? 'var(--status-ok)' : 'var(--status-critical)';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: 'var(--space-2)',
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-sm)'
    }
  }, cards.filter(c => !c.error).map(c => /*#__PURE__*/React.createElement("div", {
    key: c.name,
    style: {
      display: 'grid',
      gap: '2px',
      paddingBottom: 'var(--space-3)'
    }
  }, [0, 2].map(start => {
    const pair = (c.windows || []).slice(start, start + 2);
    if (!pair.length) return null;
    return /*#__PURE__*/React.createElement("div", {
      key: start,
      style: {
        display: 'grid',
        gridTemplateColumns: '132px 1fr 1fr',
        gap: 'var(--cell-x)'
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        color: start === 0 ? window.ZeroDeltaDesignSystem_9449d1.PROVIDER_ACCENTS[c.name] || 'var(--accent-text)' : 'transparent',
        fontWeight: 'var(--weight-bold)'
      }
    }, c.name), pair.map(w => /*#__PURE__*/React.createElement("span", {
      key: w.label,
      style: {
        color: tint(w.pace || 'n/a')
      }
    }, w.label, ":", w.percent, "% ", arrow(w.pace || 'n/a'))));
  }))));
}

/** The full terminal dashboard: header, packed cards or compact lines, key hints. */
function CliDashboard({
  cards,
  depleted = [],
  updatedAt,
  refresh,
  updating,
  narrow,
  fixKeys = []
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: 'var(--cell-y)'
    }
  }, /*#__PURE__*/React.createElement(HeaderBar, {
    updatedAt: updatedAt,
    refresh: refresh,
    updating: updating
  }), narrow ? /*#__PURE__*/React.createElement(CompactLines, {
    cards: cards
  }) : /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement(PackedStacks, {
    cards: cards
  }), /*#__PURE__*/React.createElement(MicroDepleted, {
    cards: depleted
  })), /*#__PURE__*/React.createElement(FooterHint, {
    keys: [{
      key: 'q',
      action: 'quit'
    }, {
      key: 'r',
      action: 'refresh'
    }, ...fixKeys]
  }));
}
Object.assign(window, {
  CliDashboard,
  PackedStacks,
  CompactLines,
  MicroDepleted
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/gradus-cli/Dashboard.jsx", error: String((e && e.message) || e) }); }

// ui_kits/gradus-cli/Warmup.jsx
try { (() => {
const {
  Panel,
  HeaderBar,
  FooterHint
} = window.ZeroDeltaDesignSystem_9449d1;

/** Startup screen: spinner, the two reassurance lines, and the standing key hints. */
function WarmupScreen({
  updatedAt,
  elapsed
}) {
  const frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
  const [i, setI] = React.useState(0);
  React.useEffect(() => {
    const t = setInterval(() => setI(n => (n + 1) % frames.length), 80);
    return () => clearInterval(t);
  }, []);
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: 'var(--cell-y)'
    }
  }, /*#__PURE__*/React.createElement(HeaderBar, {
    updatedAt: updatedAt,
    refresh: elapsed
  }), /*#__PURE__*/React.createElement(Panel, {
    title: /*#__PURE__*/React.createElement("span", {
      style: {
        color: 'var(--accent-text)',
        fontWeight: 'var(--weight-bold)'
      }
    }, "Warming Up"),
    subtitle: /*#__PURE__*/React.createElement("span", {
      style: {
        fontFamily: 'var(--font-mono-ui)',
        fontSize: 'var(--text-2xs)',
        color: 'var(--text-muted)'
      }
    }, "getting initial usage")
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-sm)',
      display: 'grid',
      gap: '2px'
    }
  }, /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--accent-text)'
    }
  }, frames[i]), " ", /*#__PURE__*/React.createElement("span", {
    style: {
      color: 'var(--text-primary)'
    }
  }, "probing 7 providers \u2026")), /*#__PURE__*/React.createElement("div", {
    style: {
      color: 'var(--text-muted)'
    }
  }, "First refresh can take a few seconds."), /*#__PURE__*/React.createElement("div", {
    style: {
      color: 'var(--text-muted)'
    }
  }, "Credentials are read locally; nothing is uploaded."))), /*#__PURE__*/React.createElement(FooterHint, null));
}
Object.assign(window, {
  WarmupScreen
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/gradus-cli/Warmup.jsx", error: String((e && e.message) || e) }); }

// ui_kits/gradus-mac/MenuPopover.jsx
try { (() => {
const {
  UsageBar,
  Toggle,
  Button,
  StatusBadge
} = window.ZeroDeltaDesignSystem_9449d1;
const ACC = window.ZeroDeltaDesignSystem_9449d1.PROVIDER_ACCENTS;

/** One compact row: name, worst window's bar + percent, then reset and pace metadata. */
function MenuProviderRow({
  provider
}) {
  const worst = (provider.windows || []).reduce((a, b) => a && a.percent <= b.percent ? a : b, null);
  return /*#__PURE__*/React.createElement("div", {
    style: {
      padding: 'var(--space-1) 0',
      display: 'grid',
      gap: 'var(--space-1)'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 'var(--space-2)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--text-xs)',
      fontWeight: 'var(--weight-semibold)',
      color: 'var(--text-primary)'
    }
  }, provider.name), provider.warning ? /*#__PURE__*/React.createElement(StatusBadge, {
    tone: "warning",
    boxed: false
  }, "[!]") : null, provider.offline ? /*#__PURE__*/React.createElement(StatusBadge, {
    tone: "offline",
    boxed: false
  }, "(offline ", provider.offline, ")") : null, /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto',
      width: '6px',
      height: '6px',
      borderRadius: 'var(--radius-pill)',
      background: ACC[provider.name] || 'var(--accent)'
    }
  })), provider.error ? /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-2xs)',
      color: 'var(--status-critical)'
    }
  }, provider.error) : /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 'var(--space-4)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1
    }
  }, /*#__PURE__*/React.createElement(UsageBar, {
    percent: worst ? worst.percent : null,
    variant: "capsule"
  })), /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-2xs)',
      color: 'var(--text-primary)',
      width: '34px',
      textAlign: 'right'
    }
  }, worst ? worst.percent + '%' : 'n/a')), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 'var(--space-4)',
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-3xs)',
      color: 'var(--text-muted)'
    }
  }, /*#__PURE__*/React.createElement("span", null, "reset ", worst ? worst.reset : 'n/a'), /*#__PURE__*/React.createElement("span", null, worst ? worst.pace : ''))));
}

/** The MenuBarExtra dropdown: 260px, provider rows, two settings toggles, quit. */
function MenuPopover({
  providers,
  sync,
  setSync,
  launch,
  setLaunch,
  published
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      width: 'var(--menu-width)',
      padding: 'var(--space-5)',
      display: 'grid',
      gap: 'var(--space-4)',
      background: 'var(--surface-raised)',
      border: 'var(--border-hair) solid var(--border-hairline)',
      borderRadius: 'var(--radius-lg)',
      boxShadow: 'var(--shadow-menu)'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'baseline',
      gap: 'var(--space-2)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--text-base)',
      fontWeight: 'var(--weight-semibold)'
    }
  }, "Gradus"), /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto',
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-3xs)',
      color: 'var(--text-muted)'
    }
  }, published)), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid'
    }
  }, providers.length === 0 ? /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--text-xs)',
      color: 'var(--text-muted)'
    }
  }, "No snapshot data yet") : providers.map(p => /*#__PURE__*/React.createElement(MenuProviderRow, {
    key: p.name,
    provider: p
  }))), /*#__PURE__*/React.createElement("span", {
    style: {
      height: '1px',
      background: 'var(--border-hairline)'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: 'var(--space-3)'
    }
  }, /*#__PURE__*/React.createElement(Toggle, {
    label: "Enable iCloud Sync",
    checked: sync,
    onChange: setSync
  }), /*#__PURE__*/React.createElement(Toggle, {
    label: "Launch at Login",
    checked: launch,
    onChange: setLaunch
  })), /*#__PURE__*/React.createElement("span", {
    style: {
      height: '1px',
      background: 'var(--border-hairline)'
    }
  }), /*#__PURE__*/React.createElement(Button, {
    size: "sm",
    variant: "plain",
    title: "Quit the Gradus menu bar app",
    style: {
      justifySelf: 'start',
      padding: '2px 0'
    }
  }, "Quit Gradus"));
}
Object.assign(window, {
  MenuPopover,
  MenuProviderRow
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/gradus-mac/MenuPopover.jsx", error: String((e && e.message) || e) }); }

// ui_kits/gradus-mobile/Screens.jsx
try { (() => {
const {
  MobileNavBar,
  StatTile,
  ListRow,
  Toggle,
  Button,
  Shield,
  EmptyState,
  UsageBar,
  StatusBadge,
  PaceIndicator,
  Icon,
  IconButton
} = window.ZeroDeltaDesignSystem_9449d1;
const ACC = window.ZeroDeltaDesignSystem_9449d1.PROVIDER_ACCENTS;
const worst = p => (p.windows || []).reduce((a, b) => a && a.percent <= b.percent ? a : b, null);
const rest = p => (p.windows || []).filter(w => w !== worst(p)).map(w => ({
  label: w.label,
  percent: w.percent
}));

/** Screen 1 — Now: one hero tile for the provider closest to depletion, then every provider. */
function NowScreen({
  providers,
  sync,
  setSync,
  onOpen,
  onSettings,
  published
}) {
  const ranked = [...providers].sort((a, b) => (worst(a) ? worst(a).percent : 101) - (worst(b) ? worst(b).percent : 101));
  const [head, ...tail] = ranked;
  const hw = worst(head);
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: 'var(--space-5)',
      padding: '52px 0 40px'
    }
  }, /*#__PURE__*/React.createElement(MobileNavBar, {
    title: "Now",
    eyebrow: published,
    trailing: /*#__PURE__*/React.createElement(IconButton, {
      name: "settings",
      label: "Open Gradus settings",
      onPress: onSettings
    })
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: 'var(--space-4)',
      padding: '0 var(--space-6)'
    }
  }, /*#__PURE__*/React.createElement(StatTile, {
    hero: true,
    title: head.name,
    dotColor: ACC[head.name],
    value: hw.percent,
    pace: hw.pace,
    warning: head.warning,
    meta: hw.label + ' window · resets ' + hw.reset + ' · ' + hw.countdown,
    onPress: () => onOpen(head.name)
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-2xs)',
      letterSpacing: 'var(--tracking-wide)',
      color: 'var(--text-muted)',
      paddingTop: 'var(--space-2)'
    }
  }, "ALL PROVIDERS"), tail.map(p => {
    const w = worst(p);
    return /*#__PURE__*/React.createElement(StatTile, {
      key: p.name,
      title: p.name,
      dotColor: ACC[p.name],
      value: w ? w.percent : null,
      chips: rest(p),
      pace: w ? w.pace : undefined,
      warning: p.warning,
      badge: p.offline ? 'offline ' + p.offline : p.badge === 'live' ? undefined : p.badge,
      badgeTone: p.offline ? 'offline' : 'cached',
      meta: w ? w.label + ' · resets ' + w.reset : 'no window data',
      onPress: () => onOpen(p.name)
    });
  })));
}

/** Screen 2 — Provider detail: every window at full size, then provenance. */
function ProviderScreen({
  provider,
  onBack
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: 'var(--space-5)',
      padding: '52px 0 40px'
    }
  }, /*#__PURE__*/React.createElement(MobileNavBar, {
    title: provider.name,
    eyebrow: provider.offline ? 'OFFLINE ' + provider.offline.toUpperCase() : 'LIVE · API',
    onBack: onBack,
    backLabel: "Now",
    trailing: provider.warning ? /*#__PURE__*/React.createElement(StatusBadge, {
      tone: "warning",
      boxed: false
    }, "[!]") : null
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: 'var(--space-4)',
      padding: '0 var(--space-6)'
    }
  }, (provider.windows || []).map(w => /*#__PURE__*/React.createElement("div", {
    key: w.label,
    style: {
      display: 'grid',
      gap: 'var(--space-3)',
      padding: 'var(--space-5)',
      background: 'var(--surface-card)',
      border: 'var(--border-hair) solid var(--border-hairline)',
      borderRadius: 'var(--radius-lg)'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'baseline',
      gap: 'var(--space-3)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-sm)',
      color: 'var(--text-muted)'
    }
  }, w.label), /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--text-sm)',
      color: 'var(--text-secondary)'
    }
  }, w.name), /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto'
    }
  }, /*#__PURE__*/React.createElement(PaceIndicator, {
    label: w.pace
  }))), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'baseline',
      gap: 'var(--space-2)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-2xl)',
      color: w.percent >= 70 ? 'var(--status-ok)' : w.percent >= 40 ? 'var(--status-pace)' : w.percent >= 20 ? 'var(--status-low)' : 'var(--status-critical)'
    }
  }, w.percent, "%"), /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-2xs)',
      color: 'var(--text-muted)'
    }
  }, "remaining")), /*#__PURE__*/React.createElement(UsageBar, {
    percent: w.percent,
    variant: "capsule",
    height: "var(--bar-height-app)"
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 'var(--space-5)',
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-2xs)',
      color: 'var(--text-muted)'
    }
  }, /*#__PURE__*/React.createElement("span", null, "resets ", w.reset), /*#__PURE__*/React.createElement("span", null, w.countdown)))), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 'var(--space-3)',
      flexWrap: 'wrap',
      paddingTop: 'var(--space-2)'
    }
  }, /*#__PURE__*/React.createElement(Shield, {
    label: "source",
    value: "api",
    tone: "ok"
  }), /*#__PURE__*/React.createElement(Shield, {
    label: "schema",
    value: "v2"
  }), /*#__PURE__*/React.createElement(Shield, {
    label: "observed",
    value: "41s ago"
  }))));
}

/** Screen 3 — Settings: grouped rows, sync off by default, one warning threshold. */
function SettingsScreen({
  onBack,
  sync,
  setSync,
  notify,
  setNotify
}) {
  const group = rows => /*#__PURE__*/React.createElement("div", {
    style: {
      background: 'var(--surface-card)',
      border: 'var(--border-hair) solid var(--border-hairline)',
      borderRadius: 'var(--radius-lg)',
      overflow: 'hidden'
    }
  }, rows);
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: 'var(--space-5)',
      padding: '52px 0 40px'
    }
  }, /*#__PURE__*/React.createElement(MobileNavBar, {
    title: "Settings",
    onBack: onBack,
    backLabel: "Now"
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gap: 'var(--space-6)',
      padding: '0 var(--space-6)'
    }
  }, group([/*#__PURE__*/React.createElement(ListRow, {
    key: "s",
    title: "iCloud Sync",
    subtitle: "opt-in per device, off by default",
    accessory: /*#__PURE__*/React.createElement(Toggle, {
      label: "iCloud Sync",
      checked: sync,
      onChange: setSync,
      labelsHidden: true
    })
  }), /*#__PURE__*/React.createElement(ListRow, {
    key: "n",
    title: "Warning Notifications",
    subtitle: "one banner per window, per crossing",
    accessory: /*#__PURE__*/React.createElement(Toggle, {
      label: "Warning Notifications",
      checked: notify,
      onChange: setNotify,
      labelsHidden: true
    }),
    isLast: true
  })]), group([/*#__PURE__*/React.createElement(ListRow, {
    key: "t",
    title: "Warning Threshold",
    value: "20%",
    chevron: true
  }), /*#__PURE__*/React.createElement(ListRow, {
    key: "p",
    title: "Publishing Mac",
    subtitle: "last published 41s ago",
    value: "MacBook Pro",
    chevron: true,
    isLast: true
  })]), group([/*#__PURE__*/React.createElement(ListRow, {
    key: "pr",
    title: "Providers",
    value: "7 tracked",
    chevron: true
  }), /*#__PURE__*/React.createElement(ListRow, {
    key: "a",
    title: "About Gradus",
    subtitle: "reads a credential-free snapshot only",
    chevron: true,
    isLast: true
  })]), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 'var(--space-3)',
      flexWrap: 'wrap'
    }
  }, /*#__PURE__*/React.createElement(Shield, {
    label: "gradus",
    value: "ios 0.1",
    tone: "accent"
  }), /*#__PURE__*/React.createElement(Shield, {
    label: "schema",
    value: "v2"
  }), /*#__PURE__*/React.createElement(Shield, {
    label: "credentials",
    value: "never synced",
    tone: "ok"
  }))));
}

/** Screen 4 — the three empty states, verbatim from EmptyStateView.swift; SF Symbols map to Lucide. */
function EmptyScreen({
  state,
  onEnableSync
}) {
  const COPY = {
    syncDisabled: {
      sf: 'icloud.slash',
      title: 'iCloud Sync Is Off',
      message: 'Turn on iCloud sync to see usage data from your Mac.',
      actionLabel: 'Enable iCloud Sync'
    },
    notSignedIn: {
      sf: 'person.crop.circle.badge.exclamationmark',
      title: 'Not Signed In to iCloud',
      message: 'Sign in to iCloud in Settings to see usage data from your Mac.',
      actionLabel: 'Open Settings'
    },
    waiting: {
      sf: 'hourglass',
      title: 'Waiting for First Publish',
      message: 'Sync is on. This fills in once your Mac publishes its first snapshot.'
    }
  }[state];
  const glyph = /*#__PURE__*/React.createElement(Icon, {
    name: COPY.sf,
    size: 44,
    color: "var(--text-muted)"
  });
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gridTemplateRows: 'auto 1fr',
      padding: '52px 0 40px',
      height: '100%'
    }
  }, /*#__PURE__*/React.createElement(MobileNavBar, {
    title: "Now"
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      alignContent: 'center'
    }
  }, /*#__PURE__*/React.createElement(EmptyState, {
    glyph: glyph,
    title: COPY.title,
    message: COPY.message,
    actionLabel: COPY.actionLabel,
    onAction: onEnableSync
  })));
}

/** The local notification banner raised when a provider's warning flag flips. */
function WarningBanner({
  text,
  onDismiss
}) {
  return /*#__PURE__*/React.createElement("div", {
    onClick: onDismiss,
    title: "Dismiss the Gradus warning notification",
    style: {
      position: 'absolute',
      top: '56px',
      left: '12px',
      right: '12px',
      zIndex: 70,
      padding: 'var(--space-4) var(--space-5)',
      borderRadius: 'var(--radius-lg)',
      background: 'rgba(35,35,42,.92)',
      backdropFilter: 'blur(12px)',
      border: 'var(--border-hair) solid var(--status-critical)',
      boxShadow: 'var(--shadow-menu)',
      display: 'grid',
      gap: '2px',
      cursor: 'pointer'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 'var(--space-2)'
    }
  }, /*#__PURE__*/React.createElement(Icon, {
    name: "triangle-alert",
    size: 14,
    color: "var(--status-critical)"
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-sans)',
      fontSize: 'var(--text-sm)',
      fontWeight: 'var(--weight-semibold)'
    }
  }, "Gradus"), /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto',
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-3xs)',
      color: 'var(--text-muted)'
    }
  }, "now")), /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--font-mono-ui)',
      fontSize: 'var(--text-xs)',
      color: 'var(--status-critical)'
    }
  }, text));
}
Object.assign(window, {
  NowScreen,
  ProviderScreen,
  SettingsScreen,
  EmptyScreen,
  WarningBanner
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/gradus-mobile/Screens.jsx", error: String((e && e.message) || e) }); }

// ui_kits/gradus-mobile/data.js
try { (() => {
/* Mobile fixture: same snapshot fields, plus the countdown labels the phone shows. */
window.GRADUS_MOBILE = [{
  name: 'Claude',
  badge: 'live',
  warning: true,
  windows: [{
    label: '5h',
    name: 'Session window',
    percent: 7,
    reset: '22:00',
    countdown: 'in 1h 29m',
    pace: 'over -23pt'
  }, {
    label: '1w',
    name: 'Weekly window',
    percent: 48,
    reset: 'Mar 17 15:59',
    countdown: 'in 3d 19h',
    pace: 'over -6pt'
  }]
}, {
  name: 'Cursor',
  offline: '3m',
  windows: [{
    label: 'ac',
    name: 'Auto + Composer',
    percent: 31,
    reset: 'Apr 01 00:00',
    countdown: 'in 18d',
    pace: 'over -11pt'
  }, {
    label: 'ap',
    name: 'API pool',
    percent: 88,
    reset: 'Apr 01 00:00',
    countdown: 'in 18d',
    pace: 'under +19pt'
  }]
}, {
  name: 'OpenCode Go',
  badge: 'cached 12m',
  windows: [{
    label: 'mo',
    name: 'Monthly quota',
    percent: 41,
    reset: 'Apr 02 00:00',
    countdown: 'in 19d',
    pace: 'over -8pt'
  }, {
    label: '5h',
    name: 'Session window',
    percent: 92,
    reset: '19:05',
    countdown: 'in 4h 12m',
    pace: 'under +21pt'
  }, {
    label: '1w',
    name: 'Weekly window',
    percent: 88,
    reset: 'Mar 20 08:00',
    countdown: 'in 6d 23h',
    pace: 'under +14pt'
  }]
}, {
  name: 'Copilot',
  badge: 'live',
  windows: [{
    label: 'mo',
    name: 'Premium requests',
    percent: 63,
    reset: 'Apr 01 00:00',
    countdown: 'in 18d',
    pace: 'on pace'
  }]
}, {
  name: 'Codex',
  badge: 'live',
  windows: [{
    label: '5h',
    name: 'Session window',
    percent: 74,
    reset: '13:16',
    countdown: 'in 4h 46m',
    pace: 'under +38pt'
  }, {
    label: '1w',
    name: 'Weekly window',
    percent: 85,
    reset: 'Mar 18 09:00',
    countdown: 'in 4d 0h',
    pace: 'on pace'
  }]
}, {
  name: 'Antigravity',
  badge: 'live',
  windows: [{
    label: '5h',
    name: 'Gemini 5-hour',
    percent: 100,
    reset: '18:30',
    countdown: 'in 3h 30m',
    pace: 'under +12pt'
  }, {
    label: '1w',
    name: 'Gemini weekly',
    percent: 74,
    reset: 'Mar 18 09:00',
    countdown: 'in 4d 0h',
    pace: 'on pace'
  }, {
    label: 'cg5',
    name: 'Claude + GPT 5-hour',
    percent: 62,
    reset: '18:30',
    countdown: 'in 3h 30m',
    pace: 'under +9pt'
  }]
}];
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/gradus-mobile/data.js", error: String((e && e.message) || e) }); }

// ui_kits/gradus-mobile/ios-frame.jsx
try { (() => {
// @ds-adherence-ignore -- omelette starter scaffold (raw elements/hex/px by design)
// Copied omelette starter. Re-running copy_starter_component with this kind overwrites this file with the latest version (page content is unaffected).

/* BEGIN USAGE */
// iOS.jsx — Simplified iOS 26 (Liquid Glass) device frame
// Based on the iOS 26 UI Kit + Figma status bar spec. No assets, no deps.
// Exports (to window): IOSDevice, IOSStatusBar, IOSNavBar, IOSGlassPill, IOSList, IOSListRow, IOSKeyboard
//
// Usage — wrap your screen content in <IOSDevice> to get the bezel, status bar
// and home indicator (props: title, dark, keyboard):
//
//   <IOSDevice title="Settings">
//     ...your screen content...
//   </IOSDevice>
//   <IOSDevice dark title="Search" keyboard>…</IOSDevice>
/* END USAGE */

// ─────────────────────────────────────────────────────────────
// Status bar
// ─────────────────────────────────────────────────────────────
function IOSStatusBar({
  dark = false,
  time = '9:41'
}) {
  const c = dark ? '#fff' : '#000';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 154,
      alignItems: 'center',
      justifyContent: 'center',
      padding: '21px 24px 19px',
      boxSizing: 'border-box',
      position: 'relative',
      zIndex: 20,
      width: '100%'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      height: 22,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      paddingTop: 1.5
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: '-apple-system, "SF Pro", system-ui',
      fontWeight: 590,
      fontSize: 17,
      lineHeight: '22px',
      color: c
    }
  }, time)), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      height: 22,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 7,
      paddingTop: 1,
      paddingRight: 1
    }
  }, /*#__PURE__*/React.createElement("svg", {
    width: "19",
    height: "12",
    viewBox: "0 0 19 12"
  }, /*#__PURE__*/React.createElement("rect", {
    x: "0",
    y: "7.5",
    width: "3.2",
    height: "4.5",
    rx: "0.7",
    fill: c
  }), /*#__PURE__*/React.createElement("rect", {
    x: "4.8",
    y: "5",
    width: "3.2",
    height: "7",
    rx: "0.7",
    fill: c
  }), /*#__PURE__*/React.createElement("rect", {
    x: "9.6",
    y: "2.5",
    width: "3.2",
    height: "9.5",
    rx: "0.7",
    fill: c
  }), /*#__PURE__*/React.createElement("rect", {
    x: "14.4",
    y: "0",
    width: "3.2",
    height: "12",
    rx: "0.7",
    fill: c
  })), /*#__PURE__*/React.createElement("svg", {
    width: "17",
    height: "12",
    viewBox: "0 0 17 12"
  }, /*#__PURE__*/React.createElement("path", {
    d: "M8.5 3.2C10.8 3.2 12.9 4.1 14.4 5.6L15.5 4.5C13.7 2.7 11.2 1.5 8.5 1.5C5.8 1.5 3.3 2.7 1.5 4.5L2.6 5.6C4.1 4.1 6.2 3.2 8.5 3.2Z",
    fill: c
  }), /*#__PURE__*/React.createElement("path", {
    d: "M8.5 6.8C9.9 6.8 11.1 7.3 12 8.2L13.1 7.1C11.8 5.9 10.2 5.1 8.5 5.1C6.8 5.1 5.2 5.9 3.9 7.1L5 8.2C5.9 7.3 7.1 6.8 8.5 6.8Z",
    fill: c
  }), /*#__PURE__*/React.createElement("circle", {
    cx: "8.5",
    cy: "10.5",
    r: "1.5",
    fill: c
  })), /*#__PURE__*/React.createElement("svg", {
    width: "27",
    height: "13",
    viewBox: "0 0 27 13"
  }, /*#__PURE__*/React.createElement("rect", {
    x: "0.5",
    y: "0.5",
    width: "23",
    height: "12",
    rx: "3.5",
    stroke: c,
    strokeOpacity: "0.35",
    fill: "none"
  }), /*#__PURE__*/React.createElement("rect", {
    x: "2",
    y: "2",
    width: "20",
    height: "9",
    rx: "2",
    fill: c
  }), /*#__PURE__*/React.createElement("path", {
    d: "M25 4.5V8.5C25.8 8.2 26.5 7.2 26.5 6.5C26.5 5.8 25.8 4.8 25 4.5Z",
    fill: c,
    fillOpacity: "0.4"
  }))));
}

// ─────────────────────────────────────────────────────────────
// Liquid glass pill — blur + tint + shine
// ─────────────────────────────────────────────────────────────
function IOSGlassPill({
  children,
  dark = false,
  style = {}
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      height: 44,
      minWidth: 44,
      borderRadius: 9999,
      position: 'relative',
      overflow: 'hidden',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      boxShadow: dark ? '0 2px 6px rgba(0,0,0,0.35), 0 6px 16px rgba(0,0,0,0.2)' : '0 1px 3px rgba(0,0,0,0.07), 0 3px 10px rgba(0,0,0,0.06)',
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: 0,
      borderRadius: 9999,
      backdropFilter: 'blur(12px) saturate(180%)',
      WebkitBackdropFilter: 'blur(12px) saturate(180%)',
      background: dark ? 'rgba(120,120,128,0.28)' : 'rgba(255,255,255,0.5)'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: 0,
      borderRadius: 9999,
      boxShadow: dark ? 'inset 1.5px 1.5px 1px rgba(255,255,255,0.15), inset -1px -1px 1px rgba(255,255,255,0.08)' : 'inset 1.5px 1.5px 1px rgba(255,255,255,0.7), inset -1px -1px 1px rgba(255,255,255,0.4)',
      border: dark ? '0.5px solid rgba(255,255,255,0.15)' : '0.5px solid rgba(0,0,0,0.06)'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      zIndex: 1,
      display: 'flex',
      alignItems: 'center',
      padding: '0 4px'
    }
  }, children));
}

// ─────────────────────────────────────────────────────────────
// Navigation bar — glass pills + large title
// ─────────────────────────────────────────────────────────────
function IOSNavBar({
  title = 'Title',
  dark = false,
  trailingIcon = true
}) {
  const muted = dark ? 'rgba(255,255,255,0.6)' : '#404040';
  const text = dark ? '#fff' : '#000';
  const pillIcon = content => /*#__PURE__*/React.createElement(IOSGlassPill, {
    dark: dark
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      width: 36,
      height: 36,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center'
    }
  }, content));
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 10,
      paddingTop: 62,
      paddingBottom: 10,
      position: 'relative',
      zIndex: 5
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      padding: '0 16px'
    }
  }, pillIcon(/*#__PURE__*/React.createElement("svg", {
    width: "12",
    height: "20",
    viewBox: "0 0 12 20",
    fill: "none",
    style: {
      marginLeft: -1
    }
  }, /*#__PURE__*/React.createElement("path", {
    d: "M10 2L2 10l8 8",
    stroke: muted,
    strokeWidth: "2.5",
    strokeLinecap: "round",
    strokeLinejoin: "round"
  }))), trailingIcon && pillIcon(/*#__PURE__*/React.createElement("svg", {
    width: "22",
    height: "6",
    viewBox: "0 0 22 6"
  }, /*#__PURE__*/React.createElement("circle", {
    cx: "3",
    cy: "3",
    r: "2.5",
    fill: muted
  }), /*#__PURE__*/React.createElement("circle", {
    cx: "11",
    cy: "3",
    r: "2.5",
    fill: muted
  }), /*#__PURE__*/React.createElement("circle", {
    cx: "19",
    cy: "3",
    r: "2.5",
    fill: muted
  })))), /*#__PURE__*/React.createElement("div", {
    style: {
      padding: '0 16px',
      fontFamily: '-apple-system, system-ui',
      fontSize: 34,
      fontWeight: 700,
      lineHeight: '41px',
      color: text,
      letterSpacing: 0.4
    }
  }, title));
}

// ─────────────────────────────────────────────────────────────
// Grouped list (inset card, r:26) + row (52px)
// ─────────────────────────────────────────────────────────────
function IOSListRow({
  title,
  detail,
  icon,
  chevron = true,
  isLast = false,
  dark = false
}) {
  const text = dark ? '#fff' : '#000';
  const sec = dark ? 'rgba(235,235,245,0.6)' : 'rgba(60,60,67,0.6)';
  const ter = dark ? 'rgba(235,235,245,0.3)' : 'rgba(60,60,67,0.3)';
  const sep = dark ? 'rgba(84,84,88,0.65)' : 'rgba(60,60,67,0.12)';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      minHeight: 52,
      padding: '0 16px',
      position: 'relative',
      fontFamily: '-apple-system, system-ui',
      fontSize: 17,
      letterSpacing: -0.43
    }
  }, icon && /*#__PURE__*/React.createElement("div", {
    style: {
      width: 30,
      height: 30,
      borderRadius: 7,
      background: icon,
      marginRight: 12,
      flexShrink: 0
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      color: text
    }
  }, title), detail && /*#__PURE__*/React.createElement("span", {
    style: {
      color: sec,
      marginRight: 6
    }
  }, detail), chevron && /*#__PURE__*/React.createElement("svg", {
    width: "8",
    height: "14",
    viewBox: "0 0 8 14",
    style: {
      flexShrink: 0
    }
  }, /*#__PURE__*/React.createElement("path", {
    d: "M1 1l6 6-6 6",
    stroke: ter,
    strokeWidth: "2",
    fill: "none",
    strokeLinecap: "round",
    strokeLinejoin: "round"
  })), !isLast && /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      bottom: 0,
      right: 0,
      left: icon ? 58 : 16,
      height: 0.5,
      background: sep
    }
  }));
}
function IOSList({
  header,
  children,
  dark = false
}) {
  const hc = dark ? 'rgba(235,235,245,0.6)' : 'rgba(60,60,67,0.6)';
  const bg = dark ? '#1C1C1E' : '#fff';
  return /*#__PURE__*/React.createElement("div", null, header && /*#__PURE__*/React.createElement("div", {
    style: {
      fontFamily: '-apple-system, system-ui',
      fontSize: 13,
      color: hc,
      textTransform: 'uppercase',
      padding: '8px 36px 6px',
      letterSpacing: -0.08
    }
  }, header), /*#__PURE__*/React.createElement("div", {
    style: {
      background: bg,
      borderRadius: 26,
      margin: '0 16px',
      overflow: 'hidden'
    }
  }, children));
}

// ─────────────────────────────────────────────────────────────
// Device frame
// ─────────────────────────────────────────────────────────────
function IOSDevice({
  children,
  width = 402,
  height = 874,
  dark = false,
  title,
  keyboard = false
}) {
  return (
    /*#__PURE__*/
    // data-om-starter: inert presence marker — Claude Design's starter-usage
    // probe reads it; it renders nothing. Keep it on this root element.
    React.createElement("div", {
      "data-om-starter": "ios-frame",
      style: {
        width,
        height,
        borderRadius: 48,
        overflow: 'hidden',
        position: 'relative',
        background: dark ? '#000' : '#F2F2F7',
        boxShadow: '0 40px 80px rgba(0,0,0,0.18), 0 0 0 1px rgba(0,0,0,0.12)',
        fontFamily: '-apple-system, system-ui, sans-serif',
        WebkitFontSmoothing: 'antialiased'
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        position: 'absolute',
        top: 11,
        left: '50%',
        transform: 'translateX(-50%)',
        width: 126,
        height: 37,
        borderRadius: 24,
        background: '#000',
        zIndex: 50
      }
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        zIndex: 10
      }
    }, /*#__PURE__*/React.createElement(IOSStatusBar, {
      dark: dark
    })), /*#__PURE__*/React.createElement("div", {
      style: {
        height: '100%',
        display: 'flex',
        flexDirection: 'column'
      }
    }, title !== undefined && /*#__PURE__*/React.createElement(IOSNavBar, {
      title: title,
      dark: dark
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        flex: 1,
        overflow: 'auto'
      }
    }, children), keyboard && /*#__PURE__*/React.createElement(IOSKeyboard, {
      dark: dark
    })), /*#__PURE__*/React.createElement("div", {
      style: {
        position: 'absolute',
        bottom: 0,
        left: 0,
        right: 0,
        zIndex: 60,
        height: 34,
        display: 'flex',
        justifyContent: 'center',
        alignItems: 'flex-end',
        paddingBottom: 8,
        pointerEvents: 'none'
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        width: 139,
        height: 5,
        borderRadius: 100,
        background: dark ? 'rgba(255,255,255,0.7)' : 'rgba(0,0,0,0.25)'
      }
    })))
  );
}

// ─────────────────────────────────────────────────────────────
// Keyboard — iOS 26 liquid glass
// ─────────────────────────────────────────────────────────────
function IOSKeyboard({
  dark = false
}) {
  const glyph = dark ? 'rgba(255,255,255,0.7)' : '#595959';
  const sugg = dark ? 'rgba(255,255,255,0.6)' : '#333';
  const keyBg = dark ? 'rgba(255,255,255,0.22)' : 'rgba(255,255,255,0.85)';

  // special-key icons
  const icons = {
    shift: /*#__PURE__*/React.createElement("svg", {
      width: "19",
      height: "17",
      viewBox: "0 0 19 17"
    }, /*#__PURE__*/React.createElement("path", {
      d: "M9.5 1L1 9.5h4.5V16h8V9.5H18L9.5 1z",
      fill: glyph
    })),
    del: /*#__PURE__*/React.createElement("svg", {
      width: "23",
      height: "17",
      viewBox: "0 0 23 17"
    }, /*#__PURE__*/React.createElement("path", {
      d: "M7 1h13a2 2 0 012 2v11a2 2 0 01-2 2H7l-6-7.5L7 1z",
      fill: "none",
      stroke: glyph,
      strokeWidth: "1.6",
      strokeLinejoin: "round"
    }), /*#__PURE__*/React.createElement("path", {
      d: "M10 5l7 7M17 5l-7 7",
      stroke: glyph,
      strokeWidth: "1.6",
      strokeLinecap: "round"
    })),
    ret: /*#__PURE__*/React.createElement("svg", {
      width: "20",
      height: "14",
      viewBox: "0 0 20 14"
    }, /*#__PURE__*/React.createElement("path", {
      d: "M18 1v6H4m0 0l4-4M4 7l4 4",
      fill: "none",
      stroke: "#fff",
      strokeWidth: "1.8",
      strokeLinecap: "round",
      strokeLinejoin: "round"
    }))
  };
  const key = (content, {
    w,
    flex,
    ret,
    fs = 25,
    k
  } = {}) => /*#__PURE__*/React.createElement("div", {
    key: k,
    style: {
      height: 42,
      borderRadius: 8.5,
      flex: flex ? 1 : undefined,
      width: w,
      minWidth: 0,
      background: ret ? '#08f' : keyBg,
      boxShadow: '0 1px 0 rgba(0,0,0,0.075)',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      fontFamily: '-apple-system, "SF Compact", system-ui',
      fontSize: fs,
      fontWeight: 458,
      color: ret ? '#fff' : glyph
    }
  }, content);
  const row = (keys, pad = 0) => /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 6.5,
      justifyContent: 'center',
      padding: `0 ${pad}px`
    }
  }, keys.map(l => key(l, {
    flex: true,
    k: l
  })));
  return /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      zIndex: 15,
      borderRadius: 27,
      overflow: 'hidden',
      padding: '11px 0 2px',
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      boxShadow: dark ? '0 -2px 20px rgba(0,0,0,0.09)' : '0 -1px 6px rgba(0,0,0,0.018), 0 -3px 20px rgba(0,0,0,0.012)'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: 0,
      borderRadius: 27,
      backdropFilter: 'blur(12px) saturate(180%)',
      WebkitBackdropFilter: 'blur(12px) saturate(180%)',
      background: dark ? 'rgba(120,120,128,0.14)' : 'rgba(255,255,255,0.25)'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: 0,
      borderRadius: 27,
      boxShadow: dark ? 'inset 1.5px 1.5px 1px rgba(255,255,255,0.15)' : 'inset 1.5px 1.5px 1px rgba(255,255,255,0.7), inset -1px -1px 1px rgba(255,255,255,0.4)',
      border: dark ? '0.5px solid rgba(255,255,255,0.15)' : '0.5px solid rgba(0,0,0,0.06)',
      pointerEvents: 'none'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 20,
      alignItems: 'center',
      padding: '8px 22px 13px',
      width: '100%',
      boxSizing: 'border-box',
      position: 'relative'
    }
  }, ['"The"', 'the', 'to'].map((w, i) => /*#__PURE__*/React.createElement(React.Fragment, {
    key: i
  }, i > 0 && /*#__PURE__*/React.createElement("div", {
    style: {
      width: 1,
      height: 25,
      background: '#ccc',
      opacity: 0.3
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      textAlign: 'center',
      fontFamily: '-apple-system, system-ui',
      fontSize: 17,
      color: sugg,
      letterSpacing: -0.43,
      lineHeight: '22px'
    }
  }, w)))), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 13,
      padding: '0 6.5px',
      width: '100%',
      boxSizing: 'border-box',
      position: 'relative'
    }
  }, row(['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p']), row(['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'], 20), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 14.25,
      alignItems: 'center'
    }
  }, key(icons.shift, {
    w: 45,
    k: 'shift'
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 6.5,
      flex: 1
    }
  }, ['z', 'x', 'c', 'v', 'b', 'n', 'm'].map(l => key(l, {
    flex: true,
    k: l
  }))), key(icons.del, {
    w: 45,
    k: 'del'
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 6,
      alignItems: 'center'
    }
  }, key('ABC', {
    w: 92.25,
    fs: 18,
    k: 'abc'
  }), key('', {
    flex: true,
    k: 'space'
  }), key(icons.ret, {
    w: 92.25,
    ret: true,
    k: 'ret'
  }))), /*#__PURE__*/React.createElement("div", {
    style: {
      height: 56,
      width: '100%',
      position: 'relative'
    }
  }));
}
Object.assign(window, {
  IOSDevice,
  IOSStatusBar,
  IOSNavBar,
  IOSGlassPill,
  IOSList,
  IOSListRow,
  IOSKeyboard
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/gradus-mobile/ios-frame.jsx", error: String((e && e.message) || e) }); }

// ui_kits/providers.js
try { (() => {
/* Shared fixture data for the Gradus UI kits — shapes match .state/snapshot-v2.json. */
window.GRADUS_FIXTURE = [{
  name: 'Antigravity',
  badge: 'live',
  windows: [{
    label: '5h',
    percent: 100,
    reset: '18:30',
    pace: 'under +12pt'
  }, {
    label: '1w',
    percent: 74,
    reset: 'Mar 18 09:00',
    pace: 'on pace'
  }, {
    label: 'cg5',
    percent: 62,
    reset: '18:30',
    pace: 'under +9pt'
  }]
}, {
  name: 'Claude',
  badge: 'live',
  warning: true,
  windows: [{
    label: '5h',
    percent: 7,
    reset: '22:00',
    pace: 'over -23pt'
  }, {
    label: '1w',
    percent: 48,
    reset: 'Mar 17 15:59',
    pace: 'over -6pt'
  }]
}, {
  name: 'Codex',
  badge: 'live',
  windows: [{
    label: '5h',
    percent: 74,
    reset: '13:16',
    pace: 'under +38pt'
  }, {
    label: '1w',
    percent: 85,
    reset: 'Mar 18 09:00',
    pace: 'on pace'
  }]
}, {
  name: 'Copilot',
  badge: 'live',
  windows: [{
    label: 'mo',
    percent: 63,
    reset: 'Apr 01 00:00',
    pace: 'on pace'
  }]
}, {
  name: 'OpenCode Go',
  badge: 'cached 12m',
  badgeTone: 'cached',
  windows: [{
    label: '5h',
    percent: 92,
    reset: '19:05',
    pace: 'under +21pt'
  }, {
    label: '1w',
    percent: 88,
    reset: 'Mar 20 08:00',
    pace: 'under +14pt'
  }, {
    label: 'mo',
    percent: 41,
    reset: 'Apr 02 00:00',
    pace: 'over -8pt'
  }]
}, {
  name: 'Cursor',
  offline: '3m',
  windows: [{
    label: 'ac',
    percent: 31,
    reset: 'Apr 01 00:00',
    pace: 'over -11pt'
  }, {
    label: 'ap',
    percent: 88,
    reset: 'Apr 01 00:00',
    pace: 'under +19pt'
  }]
}];
window.GRADUS_DEPLETED = [{
  name: 'Vibe',
  windows: [{
    label: 'mo',
    percent: 0,
    reset: 'Apr 01 00:00',
    state: 'depleted'
  }]
}];
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/providers.js", error: String((e && e.message) || e) }); }

__ds_ns.Button = __ds_scope.Button;

__ds_ns.DeepLink = __ds_scope.DeepLink;

__ds_ns.MiniIcon = __ds_scope.MiniIcon;

__ds_ns.Shield = __ds_scope.Shield;

__ds_ns.Toggle = __ds_scope.Toggle;

__ds_ns.PaceIndicator = __ds_scope.PaceIndicator;

__ds_ns.PROVIDER_ACCENTS = __ds_scope.PROVIDER_ACCENTS;

__ds_ns.ProviderCard = __ds_scope.ProviderCard;

__ds_ns.StatusBadge = __ds_scope.StatusBadge;

__ds_ns.UsageBar = __ds_scope.UsageBar;

__ds_ns.UsageRow = __ds_scope.UsageRow;

__ds_ns.EmptyState = __ds_scope.EmptyState;

__ds_ns.ErrorCard = __ds_scope.ErrorCard;

__ds_ns.FooterHint = __ds_scope.FooterHint;

__ds_ns.HeaderBar = __ds_scope.HeaderBar;

__ds_ns.Panel = __ds_scope.Panel;

__ds_ns.ICON_CDN = __ds_scope.ICON_CDN;

__ds_ns.SF_TO_LUCIDE = __ds_scope.SF_TO_LUCIDE;

__ds_ns.Icon = __ds_scope.Icon;

__ds_ns.IconButton = __ds_scope.IconButton;

__ds_ns.ListRow = __ds_scope.ListRow;

__ds_ns.MobileNavBar = __ds_scope.MobileNavBar;

__ds_ns.StatTile = __ds_scope.StatTile;

})();
