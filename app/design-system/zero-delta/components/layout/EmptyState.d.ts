import type { CSSProperties, ReactNode } from 'react';

/**
 * Centered empty state with one specific fix action — one screen per distinct cause.
 */
export interface EmptyStateProps {
  /** Single mono glyph, or an <Icon> node at 44px. */
  glyph?: ReactNode;
  title?: string;
  /** One sentence naming the cause and the fix. */
  message?: string;
  /** Omit entirely when there is nothing for the user to do. */
  actionLabel?: string;
  onAction?: () => void;
  style?: CSSProperties;
}
export function EmptyState(props: EmptyStateProps): JSX.Element;
