import type { CSSProperties } from 'react';

/** Chrome icon from the pinned Lucide static set, tinted by the inherited colour. */
export interface IconProps {
  /** Lucide name ('cloud-off') or an SF Symbol name that SF_TO_LUCIDE maps ('icloud.slash'). */
  name: string;
  /** 16 inline, 20 default chrome, 24 nav bar, 44 empty-state glyph. */
  size?: number;
  /** Any CSS colour; defaults to currentColor. */
  color?: string;
  /** Accessible label. Omit for purely decorative icons. */
  label?: string;
  style?: CSSProperties;
}
export function Icon(props: IconProps): JSX.Element;

/** 44px tappable icon button. */
export interface IconButtonProps {
  name: string;
  size?: number;
  /** Required: states the action, e.g. 'Open Gradus settings'. */
  label: string;
  onPress?: () => void;
  tone?: 'accent' | 'critical' | 'muted';
  style?: CSSProperties;
}
export function IconButton(props: IconButtonProps): JSX.Element;

/** Base URL of the pinned icon set. */
export const ICON_CDN: string;
/** SF Symbol name -> Lucide name map shared by the Swift and web surfaces. */
export const SF_TO_LUCIDE: Record<string, string>;
