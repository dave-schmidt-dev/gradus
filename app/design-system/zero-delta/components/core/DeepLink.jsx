import React from 'react';

/** Dashed-underline verification link. The title must state the destination and intent. */
export function DeepLink({ href, title, children, external = true, style }) {
  return (
    <a href={href} title={title} target={external ? '_blank' : undefined} rel={external ? 'noreferrer' : undefined}
      style={{ color: 'var(--link)', textDecoration: 'underline', textDecorationStyle: 'dashed', textUnderlineOffset: '3px', fontFamily: 'inherit', ...style }}
      onMouseEnter={(e) => { e.currentTarget.style.color = 'var(--link-hover)'; }}
      onMouseLeave={(e) => { e.currentTarget.style.color = 'var(--link)'; }}>{children}</a>
  );
}
