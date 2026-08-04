import type { CSSProperties, ReactNode } from 'react';

/** Large-title header for mobile screens. */
export interface MobileNavBarProps {
  /** Title Case screen title. */
  title: string;
  /** Optional all-caps eyebrow above the title. */
  eyebrow?: string;
  /** Show a back affordance and handle the tap. */
  onBack?: () => void;
  /** Destination name used in the back label and its accessible title. */
  backLabel?: string;
  /** One trailing accessory only (icon button, toggle, badge). */
  trailing?: ReactNode;
  style?: CSSProperties;
}
export function MobileNavBar(props: MobileNavBarProps): JSX.Element;
