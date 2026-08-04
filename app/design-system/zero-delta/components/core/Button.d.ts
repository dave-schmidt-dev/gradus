import type { CSSProperties, ReactNode } from 'react';

/**
 * Action button. One prominent button per surface, at most.
 */
export interface ButtonProps {
  /** 'prominent' accent fill, 'bordered' hairline, 'plain' text-only. */
  variant?: 'prominent' | 'bordered' | 'plain';
  size?: 'sm' | 'md';
  disabled?: boolean;
  children?: ReactNode;
  onClick?: () => void;
  /** Descriptive hover/AT text — required by the identity protocol for any action. */
  title?: string;
  style?: CSSProperties;
}
export function Button(props: ButtonProps): JSX.Element;
