import React from 'react';

/**
 * 16/32px proof-of-work icon beside a company, institution or provider name.
 * Uses a local static fallback rather than a remote favicon service.
 */
export function MiniIcon({ src, alt, title, size = 16, fallback, style }) {
  const px = size + 'px';
  return (
    <img src={src} alt={alt} title={title || alt} width={size} height={size}
      onError={(e) => { if (fallback && e.currentTarget.src !== fallback) e.currentTarget.src = fallback; }}
      style={{ width: px, height: px, objectFit: 'contain', flex: '0 0 auto', display: 'inline-block', verticalAlign: 'middle', ...style }} />
  );
}
