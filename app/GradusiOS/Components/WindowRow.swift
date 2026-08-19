import GradusKit
import SwiftUI

/// The label token is intentionally separate from the percentage signal token.
/// Labels are supporting context, but `.secondary` is too recessed on the
/// light card surface (the actual `.quaternary.opacity(0.5)` card rasterizes
/// to approximately `#DDDDDE` in the light snapshot).
enum WindowRowLabelForegroundToken {
    case readable
    /// Retained as a mutation fixture in `DensityLayoutTests`: reverting the
    /// row to this token must fail the normal-label contrast assertion.
    case recessed

    var color: Color {
        switch self {
        case .readable: .primary.opacity(0.78)
        case .recessed: .secondary
        }
    }

    /// Effective sRGB values at the rendered card surfaces. These are the
    /// actual light/dark surface tokens from the committed snapshot renderer,
    /// not a generic black/white contrast assumption.
    var effectiveForeground: (light: ContrastRGB, dark: ContrastRGB) {
        switch self {
        case .readable:
            (
                light: ContrastRGB(49, 49, 49),
                dark: ContrastRGB(207, 207, 207)
            )
        case .recessed:
            (
                light: ContrastRGB(131, 131, 135),
                dark: ContrastRGB(148, 148, 155)
            )
        }
    }
}

/// Small, platform-independent color representation for deterministic WCAG
/// assertions. SwiftUI's semantic colors are environment-dependent, so tests
/// use the resolved values from the actual provider-card surfaces.
struct ContrastRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            let normalized = component / 255
            return normalized <= 0.03928
                ? normalized / 12.92
                : pow((normalized + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrastRatio(with other: ContrastRGB) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

enum ProviderDensityCardSurfaceToken {
    /// `.quaternary.opacity(0.5)` over the light system background.
    static let light = ContrastRGB(221, 221, 222)
    /// `.quaternary.opacity(0.5)` over the dark system background.
    static let dark = ContrastRGB(37, 37, 38)
}

/// One window rendered as a single dense line: label, bar, percentage, reset.
///
/// This is the unit that makes the iPad's Option B layout work — the Now
/// screen's superseded `StatTile` showed one window per provider and hid the
/// rest behind badges, which is why seeing every pool at once previously
/// required drilling into Provider Detail for each provider in turn. At
/// roughly 22pt a row, a provider's whole set of windows costs about what that
/// one tile did.
///
/// The label column is a fixed width rather than sized to content so that bars
/// line up vertically inside a card. Ragged bar starts were the single biggest
/// readability loss when this was prototyped with an intrinsic-width label.
struct WindowRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Kept as a view-owned choice so the contrast test observes the exact
    /// token used by the rendered label. Mutating this back to `.recessed`
    /// makes the normal-size assertion fail.
    static let labelForegroundToken = WindowRowLabelForegroundToken.readable

    // `relativeTo` is intentionally compile-time. Each density rung uses a
    // different text style for each column, so keep one scaled value for every
    // column/style pair and choose the matching trio below at render time.
    @ScaledMetric(relativeTo: .caption) private var compactLabelWidth = DensityMetrics.compact.labelWidth
    @ScaledMetric(relativeTo: .caption) private var compactPercentWidth = DensityMetrics.compact.percentWidth
    @ScaledMetric(relativeTo: .caption2) private var compactResetWidth = DensityMetrics.compact.resetWidth
    @ScaledMetric(relativeTo: .footnote) private var standardLabelWidth = DensityMetrics.standard.labelWidth
    @ScaledMetric(relativeTo: .footnote) private var standardPercentWidth = DensityMetrics.standard.percentWidth
    @ScaledMetric(relativeTo: .caption) private var standardResetWidth = DensityMetrics.standard.resetWidth
    @ScaledMetric(relativeTo: .subheadline) private var largeLabelWidth = DensityMetrics.large.labelWidth
    @ScaledMetric(relativeTo: .subheadline) private var largePercentWidth = DensityMetrics.large.percentWidth
    @ScaledMetric(relativeTo: .footnote) private var largeResetWidth = DensityMetrics.large.resetWidth

    let window: ProviderWindow
    let now: Date
    /// Dropped at compact width. At `.compact` density the three fixed columns
    /// plus spacing cost 246pt, which on a 393pt iPhone leaves the bar about
    /// 91pt — squeezing the one element that actually carries the signal.
    /// Without reset the bar gets ~203pt. Reset is not lost: it stays on this
    /// row at regular width, and Provider Detail shows it on every device.
    ///
    /// Stays a width question rather than a density one even though density now
    /// scales the columns: the column either fits in the card or it doesn't.
    /// `DensityMetrics.fitsResetColumn(inCardWidth:)` is where the two axes
    /// meet, and `DensityLayoutTests` checks it at real device widths.
    let showsReset: Bool
    /// All widths, fonts and heights below come from here. Defaulted to
    /// `.compact` so the many call sites that predate the density axis keep
    /// rendering 1.6.0's geometry exactly.
    let metrics: DensityMetrics

    init(
        window: ProviderWindow,
        now: Date,
        showsReset: Bool = true,
        metrics: DensityMetrics = .compact
    ) {
        self.window = window
        self.now = now
        self.showsReset = showsReset
        self.metrics = metrics
    }

    var body: some View {
        let color = SignalColor.forWindow(window)

        Group {
            if dynamicTypeSize >= .accessibility1 {
                VStack(alignment: .leading, spacing: metrics.rowGap) {
                    HStack(spacing: metrics.columnGap) {
                        labelText
                        Spacer(minLength: 0)
                        percentText(color: color)
                    }

                    UsageBar(window: window, color: color, height: metrics.barHeight)
                        .frame(maxWidth: .infinity)

                    paceText
                }
            } else {
                VStack(alignment: .leading, spacing: metrics.rowGap) {
                    HStack(spacing: metrics.columnGap) {
                        labelText
                        UsageBar(window: window, color: color, height: metrics.barHeight)
                        percentText(color: color)

                        if showsReset {
                            Text(resetText)
                                .font(metrics.resetFont)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .frame(width: scaledResetWidth, alignment: .trailing)
                        }
                    }

                    paceText
                }
            }
        }
        .frame(minHeight: metrics.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    /// Below the bar rather than a fifth fixed column, matching Mac's
    /// `MenuWindowMetadata`: a quantitative pace figure is the ask (parity
    /// with the TUI and Mac), but the row's four columns are already sized to
    /// the width they have -- reset included, which stays exactly where it
    /// was. A full-width line only needs the text to fit, not another column
    /// budget.
    private var paceText: some View {
        Text(paceLabel(for: window))
            .font(metrics.resetFont)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    private var labelText: some View {
        Text(ProviderWindowLabel.label(for: window.id))
            .font(metrics.labelFont.weight(.medium))
            .foregroundStyle(Self.labelForegroundToken.color)
            .lineLimit(1)
            // `Monthly` and the long names must not lose their identity
            // merely because the percentage column is present. The minimum
            // holds the intended bar start while leaving the usage bar's
            // flexible allocation authoritative at narrow widths.
            .frame(minWidth: scaledLabelWidth, alignment: .leading)
    }

    private func percentText(color: Color) -> some View {
        Text(percentDisplay(window.percentLeft))
            .font(metrics.percentFont)
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(minWidth: scaledPercentWidth, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// Fixed column widths after Dynamic Type scaling, selected for the
    /// current density. These stay view-owned so `DensityMetrics` and the
    /// layout solver remain pure measurements and arithmetic.
    var scaledLabelWidth: CGFloat {
        switch metrics.rung {
        case .compact: compactLabelWidth
        case .standard: standardLabelWidth
        case .large: largeLabelWidth
        }
    }

    var scaledPercentWidth: CGFloat {
        switch metrics.rung {
        case .compact: compactPercentWidth
        case .standard: standardPercentWidth
        case .large: largePercentWidth
        }
    }

    var scaledResetWidth: CGFloat {
        switch metrics.rung {
        case .compact: compactResetWidth
        case .standard: standardResetWidth
        case .large: largeResetWidth
        }
    }

    /// Falls back to the raw ISO string only when `friendlyResetDate` cannot
    /// parse it, matching `ProviderDetailView` — showing the unparsed value is
    /// more honest than showing nothing when a provider emits an odd format.
    var resetText: String {
        guard let resetISO = window.resetISO else { return "" }
        return friendlyResetDate(resetISO, now: now) ?? resetISO
    }

    /// One spoken string for the whole row. The bar, percentage, reset and
    /// pace are four views but one fact, so VoiceOver should not stop four
    /// times.
    var spokenLabel: String {
        let label = ProviderWindowLabel.label(for: window.id)
        let percent = percentDisplay(window.percentLeft, suffix: " percent remaining")
        let pace = paceLabel(for: window)
        guard !resetText.isEmpty else { return "\(label), \(percent), \(pace)" }
        return "\(label), \(percent), resets \(resetText), \(pace)"
    }
}
