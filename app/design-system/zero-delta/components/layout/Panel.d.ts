import type { CSSProperties, ReactNode } from 'react';

/** Bordered container with an inset title, mirroring the TUI's rich Panel. */
export interface PanelProps {
  /** Title node inset into the top border (usually the accented provider name). */
  title?: ReactNode;
  /** Badge inset into the bottom-left border. */
  subtitle?: ReactNode;
  /** Border colour — provider accent, or yellow/red for offline/error states. */
  borderColor?: string;
  /** Keep var(--radius-none) on terminal surfaces; var(--radius-md) on Apple surfaces. */
  radius?: string;
  padding?: string;
  children?: ReactNode;
  style?: CSSProperties;
}
export function Panel(props: PanelProps): JSX.Element;
