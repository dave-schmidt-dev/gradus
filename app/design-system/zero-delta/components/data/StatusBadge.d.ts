import type { ReactNode } from 'react';

/** Freshness / warning badge used in provider card titles. */
export interface StatusBadgeProps {
  /** live | cached | offline | stale | warning | error. */
  tone?: 'live' | 'cached' | 'offline' | 'stale' | 'warning' | 'error';
  /** Badge text, e.g. 'live', 'cached 12m', '(offline 3m)', '[!]'. */
  children?: ReactNode;
  /** Draw the 1px box. Set false for bare inline markers like [!]. */
  boxed?: boolean;
}
export function StatusBadge(props: StatusBadgeProps): JSX.Element;
