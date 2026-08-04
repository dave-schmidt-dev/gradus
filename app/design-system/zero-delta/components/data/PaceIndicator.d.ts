import type { CSSProperties } from 'react';

/** Burn-rate label for a quota window: under / on pace / over / n-a. */
export interface PaceIndicatorProps {
  /** Verbatim product label: "under +38pt", "on pace", "over -23pt", "n/a". */
  label?: string;
  /** Render arrow notation (↑38pt / = / ↓23pt / —) for narrow columns. */
  compact?: boolean;
  style?: CSSProperties;
}
export function PaceIndicator(props: PaceIndicatorProps): JSX.Element;
/** Convert a verbose pace label to its arrow form. */
export function compactPace(label: string): string;
