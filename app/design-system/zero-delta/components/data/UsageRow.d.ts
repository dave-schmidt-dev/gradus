/** One quota window row: label | % | bar | reset | pace. */
export interface UsageRowProps {
  /** Window id as the product prints it: '5h', '1w', 'mo', 'ac', 'ap', 'cg5', 'cg1w'. */
  label: string;
  /** Percent REMAINING. null renders 'n/a' in place of the value. */
  percent?: number | null;
  /** Normalized reset display: 'HH:MM' same-day, else 'Mon DD HH:MM'. */
  reset?: string;
  /** Pace label passed through to PaceIndicator. */
  pace?: string;
  /** 'usage' full row, 'depleted' bar-less "0% until <reset>", 'na' label + n/a. */
  state?: 'usage' | 'depleted' | 'na';
  /** Drop the pace column (narrow cards). */
  compact?: boolean;
  /** Glyph cells in the bar. */
  cells?: number;
}
export function UsageRow(props: UsageRowProps): JSX.Element;
