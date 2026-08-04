import type { CSSProperties } from 'react';

/** Crisp 16/32px verification icon; object-fit contain so a logo is never squished. */
export interface MiniIconProps {
  /** Local asset path. Avoid remote favicon APIs (rate limits, broken images). */
  src: string;
  /** Descriptive alt — never the bare domain. */
  alt: string;
  /** Hover text; defaults to alt. */
  title?: string;
  size?: 16 | 32 | number;
  /** Local static fallback used if src fails. */
  fallback?: string;
  style?: CSSProperties;
}
export function MiniIcon(props: MiniIconProps): JSX.Element;
