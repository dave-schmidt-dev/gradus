import type { CSSProperties } from 'react';

/** One-line dashboard header: product | Last Updated: <stamp> | ↻ <countdown>. */
export interface HeaderBarProps {
  product?: string;
  /** Stamp in the product's format: 'Mar 13 08:30:14'. */
  updatedAt?: string;
  /** Countdown text, e.g. '57s'. */
  refresh?: string;
  /** Replace the countdown with the in-place 'updating …' state. */
  updating?: boolean;
  style?: CSSProperties;
}
export function HeaderBar(props: HeaderBarProps): JSX.Element;
