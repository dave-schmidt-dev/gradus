import type { CSSProperties } from 'react';
import type { UsageRowProps } from './UsageRow';

/**
 * One tracked AI provider as a bordered panel with its quota windows.
 */
export interface ProviderCardProps {
  /** Canonical provider name — drives the accent colour. */
  name: 'Codex' | 'Claude' | 'Antigravity' | 'Copilot' | 'Cursor' | 'Vibe' | 'OpenCode Go' | string;
  /** One entry per quota window, in product order (5h before 1w before mo). */
  windows?: UsageRowProps[];
  /** Show the red [!] marker after the name. */
  warning?: boolean;
  /** Subtitle badge text, e.g. 'live' or 'cached 12m'. */
  badge?: string;
  badgeTone?: 'live' | 'cached' | 'offline' | 'stale' | 'warning' | 'error';
  /** Age string for the "(offline 3m)" title marker; also turns the border yellow. */
  offline?: string;
  /** Drop the pace column. */
  compact?: boolean;
  cells?: number;
  style?: CSSProperties;
}
export function ProviderCard(props: ProviderCardProps): JSX.Element;
/** Provider name -> accent CSS variable. */
export const PROVIDER_ACCENTS: Record<string, string>;
