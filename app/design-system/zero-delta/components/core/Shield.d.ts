import type { CSSProperties } from 'react';

/**
 * Pure-CSS two-tone badge (label + value) — the brand's required format for skills and metadata.
 */
export interface ShieldProps {
  /** Left block: the category, lowercase ('provider', 'schema', 'python'). */
  label: string;
  /** Right block: the value ('v2', '3.10+', 'ok'). */
  value: string;
  tone?: 'neutral' | 'ok' | 'warn' | 'critical' | 'accent';
  style?: CSSProperties;
}
export function Shield(props: ShieldProps): JSX.Element;
