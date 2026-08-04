import type { CSSProperties } from 'react';

/** One-line provider failure card: hard error, auth-recovery prompt, or stale data. */
export interface ErrorCardProps {
  /** Provider name; rendered in the failure colour, not the provider accent. */
  name: string;
  /** 'error' red message, 'auth' keyboard-recovery prompt, 'stale' yellow notice. */
  tone?: 'error' | 'auth' | 'stale';
  /** Message text (truncate upstream at ~60 chars). */
  message?: string;
  /** Shortcut character for tone="auth". */
  fixKey?: string;
  style?: CSSProperties;
}
export function ErrorCard(props: ErrorCardProps): JSX.Element;
