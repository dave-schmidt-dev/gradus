import type { CSSProperties } from 'react';

/** Keyboard-shortcut hint row shown at the bottom of the TUI. */
export interface FooterHintProps {
  /** Ordered key/action pairs; keys render bracketed and cyan. */
  keys?: Array<{ key: string; action: string }>;
  style?: CSSProperties;
}
export function FooterHint(props: FooterHintProps): JSX.Element;
