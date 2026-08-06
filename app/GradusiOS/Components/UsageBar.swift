import GradusKit
import SwiftUI

/// A remaining-capacity bar with an optional expected-pace marker.
///
/// The marker is derived only through GradusKit's shared pace helper, so an
/// absent, non-finite, or invalid input never produces a fabricated rule.
struct UsageBar: View {
    private static let markerWidth: CGFloat = 3
    /// The marker overhangs the bar by this much at each end, which is what
    /// makes it readable as a rule across the bar rather than a segment of it.
    /// Held constant as the bar thickens so every density reads the same; the
    /// Mac keeps the same idea in `MenuContentView`'s
    /// `max(0, (markerHeight - barHeight) / 2)`.
    ///
    /// Only the *horizontal* geometry is shared between platforms
    /// (`GradusKit.markerOffset`) — thickness has always been per-platform
    /// (Mac 14pt against iOS's 12pt), so scaling it here does not reopen the
    /// divergence `fdecc01` closed.
    private static let markerOverhang: CGFloat = 4

    let percentLeft: Double
    let paceDelta: Double?
    let color: Color
    /// Defaulted to 1.6.0's literal so callers that predate the density axis
    /// render unchanged.
    let height: CGFloat

    init(window: ProviderWindow, color: Color? = nil, height: CGFloat = 4) {
        self.percentLeft = window.percentLeft
        self.paceDelta = window.paceDelta
        self.color = color ?? SignalColor.forWindow(window)
        self.height = height
    }

    private var markerHeight: CGFloat { height + Self.markerOverhang * 2 }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fillWidth = width * Self.clampedFraction(percentLeft)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))

                Capsule()
                    .fill(color)
                    .frame(width: fillWidth)

                if let markerPosition = Self.markerPosition(
                    percentLeft: percentLeft, paceDelta: paceDelta
                ) {
                    Rectangle()
                        .fill(SignalColor.paceMarker)
                        .frame(width: Self.markerWidth, height: markerHeight)
                        .offset(
                            x: markerOffset(
                                fraction: markerPosition,
                                barWidth: width,
                                markerWidth: Self.markerWidth
                            )
                        )
                        .zIndex(1)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(percentDisplay(percentLeft, suffix: " percent remaining"))
    }

    /// Normalized expected remaining capacity, suitable for a horizontal
    /// position in the bar. `nil` deliberately means no marker should render.
    static func markerPosition(percentLeft: Double, paceDelta: Double?) -> Double? {
        expectedRemaining(percentLeft: percentLeft, paceDelta: paceDelta).map { $0 / 100 }
    }

    private static func clampedFraction(_ percent: Double) -> Double {
        min(max(percent / 100, 0), 1)
    }
}
