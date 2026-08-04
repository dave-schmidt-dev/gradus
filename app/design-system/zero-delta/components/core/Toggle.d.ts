import type { CSSProperties } from 'react';

/** Labelled on/off switch (SwiftUI Toggle equivalent). */
export interface ToggleProps {
  /** Sentence-case label; also used as the accessible title. */
  label: string;
  checked?: boolean;
  onChange?: (next: boolean) => void;
  disabled?: boolean;
  /** Hide the visible label (toolbar placement). */
  labelsHidden?: boolean;
  style?: CSSProperties;
}
export function Toggle(props: ToggleProps): JSX.Element;
