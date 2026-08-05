import GradusKit
import SwiftUI

/// One window rendered as a single dense line: label, bar, percentage, reset.
///
/// This is the unit that makes the iPad's Option B layout work — the Now
/// screen's `StatTile` shows one window per provider and hides the rest behind
/// badges, which is why seeing every pool at once previously required drilling
/// into Provider Detail for each provider in turn. At roughly 22pt a row, a
/// provider's whole set of windows costs about what one `StatTile` did.
///
/// The label column is a fixed width rather than sized to content so that bars
/// line up vertically inside a card. Ragged bar starts were the single biggest
/// readability loss when this was prototyped with an intrinsic-width label.
struct WindowRow: View {
    /// Wide enough for "Billing Cycle", the longest label
    /// `ProviderWindowLabel` produces, at `.caption`.
    private static let labelWidth: CGFloat = 78
    private static let percentWidth: CGFloat = 40
    /// Sized for the longest string `friendlyResetDate` produces — its
    /// `MMM d, h:mm a` branch, e.g. "Aug 23, 9:30 PM". The first cut at 74
    /// truncated every absolute date to "Aug 23, 9:3…", which is worse than
    /// showing nothing: a half-rendered timestamp still reads as information.
    private static let resetWidth: CGFloat = 104

    let window: ProviderWindow
    let now: Date
    /// Dropped at compact width. The three fixed columns plus spacing cost
    /// 246pt, which on a 393pt iPhone leaves the bar about 91pt — squeezing
    /// the one element that actually carries the signal. Without reset the bar
    /// gets ~203pt. Reset is not lost: it stays on this row at regular width,
    /// and Provider Detail shows it on every device.
    let showsReset: Bool

    init(window: ProviderWindow, now: Date, showsReset: Bool = true) {
        self.window = window
        self.now = now
        self.showsReset = showsReset
    }

    var body: some View {
        let color = SignalColor.forWindow(window)

        HStack(spacing: 8) {
            Text(ProviderWindowLabel.label(for: window.id))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)

            UsageBar(window: window, color: color)

            Text("\(Int(window.percentLeft))%")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(width: Self.percentWidth, alignment: .trailing)

            if showsReset {
                Text(resetText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: Self.resetWidth, alignment: .trailing)
            }
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    /// Falls back to the raw ISO string only when `friendlyResetDate` cannot
    /// parse it, matching `ProviderDetailView` — showing the unparsed value is
    /// more honest than showing nothing when a provider emits an odd format.
    var resetText: String {
        guard let resetISO = window.resetISO else { return "" }
        return friendlyResetDate(resetISO, now: now) ?? resetISO
    }

    /// One spoken string for the whole row. The bar, percentage and reset are
    /// three views but one fact, so VoiceOver should not stop three times.
    var spokenLabel: String {
        let label = ProviderWindowLabel.label(for: window.id)
        let percent = "\(Int(window.percentLeft)) percent remaining"
        guard !resetText.isEmpty else { return "\(label), \(percent)" }
        return "\(label), \(percent), resets \(resetText)"
    }
}
