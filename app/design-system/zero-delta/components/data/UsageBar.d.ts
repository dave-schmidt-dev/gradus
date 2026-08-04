import type { CSSProperties } from 'react';

/**
 * Remaining-capacity bar in either the TUI block-glyph style or the SwiftUI capsule style.
 */
export interface UsageBarProps {
  /** Percent REMAINING (0-100). null renders the unknown state (dots / empty track). */
  percent?: number | null;
  /** 'glyph' = terminal ▓█░ bar, 'capsule' = rounded Mac/iOS bar. Default 'glyph'. */
  variant?: 'glyph' | 'capsule';
  /** Glyph cell count. Default 18. */
  cells?: number;
  /** Capsule height, e.g. var(--bar-height-app). */
  height?: string;
  /** Override the ramp colour (e.g. a provider accent). */
  color?: string;
  style?: CSSProperties;
}
export function UsageBar(props: UsageBarProps): JSX.Element;
/** Signal-ramp colour for a remaining percentage. */
export function usageColor(percent: number | null | undefined): string;
