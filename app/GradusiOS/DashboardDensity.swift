import CoreGraphics
import SwiftUI

/// How much room each provider's card is given. A *third* axis, orthogonal to
/// `DashboardLayout`'s size-class axis.
///
/// Deliberately not more cases on `DashboardLayout`. That enum answers "how
/// many columns, and is there room for a reset time" — both consequences of
/// *width*, which the user does not choose. Density is a preference. Folding
/// them together would make six states out of two independent pairs and force
/// every call site to reason about combinations that do not interact.
///
/// David, 2026-08-05: "our current version should be 'compact' with a standard
/// and large version. Large being something close to what we started with, but
/// more efficient in spacing. The standard would be between." So `.compact` is
/// exactly what shipped in 1.6.0 — its metrics are the current literals, not a
/// re-tuned approximation of them, so selecting compact reproduces 1.6.0 pixel
/// for pixel.
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

    // MARK: grid

    /// `GridItem(.adaptive(minimum:))`'s minimum.
    ///
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
    /// This is the arithmetic `showsReset` has always encoded, made explicit so
    /// it survives density: "iPhone drops reset" was only ever shorthand for
    /// "393pt minus 246pt of columns leaves 91pt of bar." Scaling the columns
    /// changes the answer at widths that used to be comfortable.
    ///
    /// Used by `DensityLayoutTests`, not at runtime. `showsReset` stays
    /// derived from `DashboardLayout` because a card inside an adaptive
    /// `LazyVGrid` cannot cheaply know its own resolved width, and the
    /// `GeometryReader` that would tell it does not size to content vertically
    /// inside a grid cell. Keeping this as a checked property of the metrics
    /// rather than a runtime branch means the numbers above are validated
    /// against the widths the app actually renders at, without adding layout
    /// machinery whose failure mode is a collapsed card.
    public func fitsResetColumn(inCardWidth cardWidth: CGFloat) -> Bool {
        let content = cardWidth - cardPadding * 2
        return content - fixedColumnWidth(showsReset: true) >= Self.minimumBarWidth
    }

    /// 1.6.0's shipped literals, unchanged. `WindowRow` and
    /// `ProviderDensityCard` read these rather than hard-coding, so the
    /// baselines recorded before the density axis existed stay valid.
    public static let compact = DensityMetrics(
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
        gridMinimum: 320
    )

    /// Between the two. Type steps up one notch (`.caption` -> `.footnote`,
    /// 12pt -> 13pt), so the fixed columns grow by roughly that ratio with a
    /// point of slack — measured, not scaled blindly, since these widths were
    /// originally set against specific strings ("Billing Cycle", "Aug 23, 9:30
    /// PM") rather than against the font's em width.
    public static let standard = DensityMetrics(
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
        gridMinimum: 460
    )
}
