import type { CSSProperties, ReactNode } from 'react';

/** Dashed-underline link that verifies a claim at its official source. */
export interface DeepLinkProps {
  href: string;
  /** Required: states intent and destination, e.g. "View Zero Delta LLC Consulting Services". */
  title: string;
  children?: ReactNode;
  /** Open in a new tab. Default true. */
  external?: boolean;
  style?: CSSProperties;
}
export function DeepLink(props: DeepLinkProps): JSX.Element;
