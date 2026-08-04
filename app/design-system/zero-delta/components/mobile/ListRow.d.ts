import type { CSSProperties, ReactNode } from 'react';

/** One row of a grouped mobile list (settings, devices, about). */
export interface ListRowProps {
  title: string;
  /** Mono metadata under the title. */
  subtitle?: string;
  /** Trailing mono value. */
  value?: string;
  /** Trailing control (Toggle, Button). */
  accessory?: ReactNode;
  chevron?: boolean;
  onPress?: () => void;
  /** Drop the hairline on the last row of a group. */
  isLast?: boolean;
  style?: CSSProperties;
}
export function ListRow(props: ListRowProps): JSX.Element;
