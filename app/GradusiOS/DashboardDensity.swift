import CoreGraphics
import SwiftUI

/// The internal presentation rung chosen for a provider card. A *third* axis,
/// orthogonal to `DashboardLayout`'s size-class axis.
///
/// Deliberately not more cases on `DashboardLayout`. That enum answers "how
/// many columns, and is there room for a reset time" — both consequences of
/// *width*, which the user does not choose. Density is a preference. Folding
/// them together would make six states out of two independent pairs and force
/// every call site to reason about combinations that do not interact.
///
/// David, 2026-08-05: "our current version should be 'compact' with a standard
/// and large version. Large being something close to what we started with, but
/// more efficient in spacing. The standard would be between." `.compact` is
/// exactly what shipped in 1.6.0 — its metrics are the current literals, not a
/// re-tuned approximation of them, so selecting this internal rung reproduces
/// 1.6.0 pixel for pixel.
///
/// The original user-facing picker became a device-relative column slider.
/// The slider chooses card width; this ladder then chooses the richest rung
/// that fits that width at the active Dynamic Type size. Keeping the rungs
/// discrete preserves semantic Dynamic Type fonts: `Font` has no meaningful
/// midpoint between `.caption`, `.footnote`, and `.subheadline`.
///
/// Every density shows *all* of a provider's windows. That is what INV-12
/// requires and what `ProviderDensityCard` exists to do: "large" means bigger
/// rows, never fewer of them. A density that hid windows would be the 1.5.0
/// divergence again, expressed as a setting.
public enum DashboardDensity: String, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case large

    public var id: Self { self }

    public var title: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        case .large: "Large"
        }
    }

    public var metrics: DensityMetrics {
        switch self {
        case .compact: .compact
        case .standard: .standard
        case .large: .large
        }
    }

    /// Walks from the richest presentation to the leanest. The caller owns
    /// the geometry question because a rung fits only after its scaled fixed
    /// columns, padding, gap, and resolved card width are known.
    ///
    /// Returning `didFit` distinguishes a compact card that genuinely clears
    /// the floor from the leanest fallback when no rung can clear it.
    static func resolveRung(
        preferred: DashboardDensity? = nil,
        fits: (DashboardDensity) -> Bool
    ) -> (rung: DashboardDensity, didFit: Bool) {
        let candidates: [DashboardDensity]
        if let preferred, let index = Self.allCases.firstIndex(of: preferred) {
            candidates = Array(Self.allCases.prefix(index + 1))
        } else {
            candidates = Array(Self.allCases)
        }
        for rung in candidates.reversed() where fits(rung) {
            return (rung, true)
        }
        return (.compact, false)
    }
}

/// The measurements a density varies. One value threaded down rather than a
/// `DashboardDensity` passed to each view, so that a view cannot re-derive
/// metrics differently from its parent — the card and the rows inside it must
/// agree or the bars stop lining up.
///
/// Note what is *absent*: `showsReset`. Whether a row can afford its reset
/// column is a width fact, not a density one — the column costs a fixed number
/// of points and either fits in the card or does not. It stays on
/// `DashboardLayout`, and `fitsResetColumn(inCardWidth:)` below is how a
/// density participates in that question without owning it.
public struct DensityMetrics: Equatable, Sendable {
    /// The discrete density rung these measurements describe. Views use this
    /// identity to select values that Dynamic Type has already scaled against
    /// the rung's compile-time text styles.
    public let rung: DashboardDensity

    // MARK: card

    /// Inset from the card's rounded background to its content.
    public let cardPadding: CGFloat
    /// Between the provider name and the first window row.
    public let titleGap: CGFloat
    /// Between adjacent window rows inside one card.
    public let rowGap: CGFloat
    /// Between cards, both axes of the grid.
    public let cardGap: CGFloat
    public let cornerRadius: CGFloat
    public let titleFont: Font

    // MARK: row

    public let rowHeight: CGFloat
    /// The usage bar's thickness. Scales with the row so a taller row does not
    /// read as a thin line marooned in whitespace.
    public let barHeight: CGFloat
    /// Between the four columns of a `WindowRow`.
    public let columnGap: CGFloat
    public let labelWidth: CGFloat
    public let percentWidth: CGFloat
    public let resetWidth: CGFloat
    public let labelFont: Font
    public let percentFont: Font
    public let resetFont: Font

    // MARK: exhausted section

    // Density governs this section too, and that is not a cosmetic nicety. The
    // reason to choose a larger density is that the small type is hard to read
    // — at viewing distance, or at all. A screen whose top half scaled and
    // whose bottom half did not would fail the request for exactly the
    // providers it applies to. The cells stay *relatively* compact at every
    // density: a spent provider raises one question and two short lines answer
    // it, which is a statement about how much of the screen it deserves, not
    // about how big the text is.

    /// The "Exhausted" heading.
    public let exhaustedHeaderFont: Font
    /// Provider name inside a cell. One notch below `titleFont` at every
    /// density, since a spent provider outranks nothing.
    public let exhaustedTitleFont: Font
    /// "resets Aug 12, 7:46 PM" — the line the cell exists for.
    public let exhaustedResetFont: Font
    /// Between a cell's two lines.
    public let exhaustedLineGap: CGFloat
    /// Between cells, around the heading, and the cell's vertical inset.
    public let exhaustedGap: CGFloat
    public let exhaustedRowHeight: CGFloat
    public let exhaustedCornerRadius: CGFloat
    // MARK: grid

    /// A density metric because David chose to scale type as well as spacing
    /// (2026-08-06). Once the three fixed columns grow, a 320pt card cannot
    /// seat them *and* a legible bar — at `.subheadline` the columns alone
    /// claim more than a 320pt card's content box, which would drive the bar to
    /// zero width rather than merely making it tight. See
    /// `DensityLayoutTests.everyDensityLeavesTheBarRoomToRead`, which asserts
    /// the arithmetic rather than trusting these numbers.
    ///
    /// The consequence is intended: at `.large` an 11" iPad in portrait seats
    /// one column and landscape two. "Close to what we started with" was a
    /// single ranked column, so large meaning *fewer, bigger* columns is the
    /// spec arriving, not a regression.
    public let gridMinimum: CGFloat

    /// A *collapse* floor, not a comfort floor. The bar is the only element
    /// carrying signal rather than a label, so it must never be squeezed to
    /// nothing by the fixed columns around it — but calling anything under
    /// 80pt unreadable would be inventing a threshold, and would indict
    /// geometry that has already shipped.
    ///
    /// 48pt is where a proportional fill stops being able to distinguish
    /// coarse states (a quarter from a half). The measured tightest case in the
    /// app today is 54.5pt: `.compact` on a 13" iPad in landscape, where the
    /// 320pt minimum packs four columns into 1334pt of content. That predates
    /// the density axis and is recorded in `TASKS.md` rather than "fixed" here,
    /// since raising `.compact`'s minimum would move every 1.6.0 baseline and
    /// break the promise that selecting compact reproduces what shipped.
    public static let minimumBarWidth: CGFloat = 48

    /// Points claimed by everything in a row that is not the bar.
    public func fixedColumnWidth(showsReset: Bool) -> CGFloat {
        let columns = labelWidth + percentWidth + (showsReset ? resetWidth : 0)
        let gaps = columnGap * (showsReset ? 3 : 2)
        return columns + gaps
    }

    /// Whether a card of `cardWidth` can seat the reset column and still leave
    /// the bar `minimumBarWidth`.
    ///
    /// Whether a resolved card can seat the reset column and still leave the
    /// bar `minimumBarWidth`.
    ///
    /// The runtime caller supplies the scaled fixed-column demand from the
    /// active Dynamic Type environment. The default keeps this arithmetic
    /// useful for callers that only have the density's unscaled measurements.
    public func fitsResetColumn(
        inCardWidth cardWidth: CGFloat,
        scaledFixedColumnWidth: CGFloat? = nil
    ) -> Bool {
        let content = cardWidth - cardPadding * 2
        let resetDemand = scaledFixedColumnWidth ?? self.fixedColumnWidth(showsReset: true)
        return content - resetDemand >= Self.minimumBarWidth
    }

    /// 1.6.0's shipped literals, unchanged. `WindowRow` and
    /// `ProviderDensityCard` read these rather than hard-coding, so the
    /// baselines recorded before the density axis existed stay valid.
    public static let compact = DensityMetrics(
        rung: .compact,
        cardPadding: 12,
        titleGap: 6,
        rowGap: 2,
        cardGap: 12,
        cornerRadius: 12,
        titleFont: .headline,
        rowHeight: 22,
        barHeight: 4,
        columnGap: 8,
        labelWidth: 78,
        percentWidth: 40,
        resetWidth: 104,
        labelFont: .caption,
        percentFont: .caption.weight(.semibold).monospacedDigit(),
        resetFont: .caption2.monospacedDigit(),
        exhaustedHeaderFont: .caption.weight(.semibold),
        exhaustedTitleFont: .subheadline,
        exhaustedResetFont: .caption,
        exhaustedLineGap: 2,
        exhaustedGap: 8,
        exhaustedRowHeight: 52,
        exhaustedCornerRadius: 10,
        gridMinimum: 320
    )

    /// Between the two. Type steps up one notch (`.caption` -> `.footnote`,
    /// 12pt -> 13pt), so the fixed columns grow by roughly that ratio with a
    /// point of slack — measured, not scaled blindly, since these widths were
    /// originally set against specific strings ("Billing Cycle", "Aug 23, 9:30
    /// PM") rather than against the font's em width.
    public static let standard = DensityMetrics(
        rung: .standard,
        cardPadding: 14,
        titleGap: 8,
        rowGap: 6,
        cardGap: 14,
        cornerRadius: 14,
        titleFont: .headline,
        rowHeight: 30,
        barHeight: 6,
        columnGap: 8,
        labelWidth: 86,
        percentWidth: 44,
        resetWidth: 114,
        labelFont: .footnote,
        percentFont: .footnote.weight(.semibold).monospacedDigit(),
        resetFont: .caption.monospacedDigit(),
        exhaustedHeaderFont: .footnote.weight(.semibold),
        exhaustedTitleFont: .callout,
        exhaustedResetFont: .footnote,
        exhaustedLineGap: 4,
        exhaustedGap: 10,
        exhaustedRowHeight: 60,
        exhaustedCornerRadius: 12,
        gridMinimum: 360
    )

    /// Roughly the pre-1.5.0 presentation with its spacing tightened. The old
    /// `StatTile` cost ~110pt to show *one* window; a large card shows a
    /// two-window provider in ~170pt, so "more efficient in spacing" holds even
    /// though each row is nearly twice a compact row's height.
    ///
    /// `resetWidth` is the number to watch. 104 was itself a correction from a
    /// first cut at 74 that truncated every absolute date to "Aug 23, 9:3…" --
    /// a half-rendered timestamp still reads as information, which is worse
    /// than omitting it. At `.subheadline` the same string needs ~130.
    public static let large = DensityMetrics(
        rung: .large,
        cardPadding: 18,
        titleGap: 12,
        rowGap: 10,
        cardGap: 16,
        cornerRadius: 16,
        titleFont: .title3.weight(.semibold),
        rowHeight: 40,
        barHeight: 8,
        columnGap: 10,
        labelWidth: 98,
        percentWidth: 50,
        resetWidth: 130,
        labelFont: .subheadline,
        percentFont: .subheadline.weight(.semibold).monospacedDigit(),
        resetFont: .footnote.monospacedDigit(),
        exhaustedHeaderFont: .subheadline.weight(.semibold),
        exhaustedTitleFont: .body,
        exhaustedResetFont: .subheadline,
        exhaustedLineGap: 6,
        exhaustedGap: 12,
        exhaustedRowHeight: 70,
        exhaustedCornerRadius: 14,
        gridMinimum: 460
    )
}
