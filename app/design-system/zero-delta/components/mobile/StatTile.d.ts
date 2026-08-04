import type { CSSProperties } from 'react';

/** Full-width mobile tile: one headline number with its bar, window chips and metadata. */
export interface StatTileProps {
  title: string;
  /** Provider accent dot; use PROVIDER_ACCENTS. */
  dotColor?: string;
  /** Headline number (percent remaining). null renders 'n/a'. */
  value?: number | null;
  /** Unit suffix. Default '%'. */
  unit?: string;
  /** Bar percentage when it differs from the headline value. */
  bar?: number;
  /** Secondary windows as label/percent chips. */
  chips?: Array<{ label: string; percent: number | null }>;
  /** Mono metadata line, e.g. 'resets 22:00 · in 1h 29m'. */
  meta?: string;
  /** Pace label shown at the end of the value row. */
  pace?: string;
  badge?: string;
  badgeTone?: 'live' | 'cached' | 'offline' | 'stale' | 'warning' | 'error';
  /** Red [!] after the title. */
  warning?: boolean;
  /** Larger type and an accent border — one per screen, at the top. */
  hero?: boolean;
  onPress?: () => void;
  style?: CSSProperties;
}
export function StatTile(props: StatTileProps): JSX.Element;
