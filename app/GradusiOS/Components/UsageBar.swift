import GradusKit
import SwiftUI

/// A remaining-capacity bar with an optional expected-pace marker.
///
/// The marker is derived only through GradusKit's shared pace helper, so an
/// absent, non-finite, or invalid input never produces a fabricated rule.
struct UsageBar: View {
    private static let markerWidth: CGFloat = 3
    private static let markerHeight: CGFloat = 12

    let percentLeft: Double
    let paceDelta: Double?
    let color: Color

    init(window: ProviderWindow, color: Color? = nil) {
        self.percentLeft = window.percentLeft
        self.paceDelta = window.paceDelta
        self.color = color ?? SignalColor.forWindow(window)
    }

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
                        .fill(.red)
                        .frame(width: Self.markerWidth, height: Self.markerHeight)
                        .offset(x: Self.markerOffset(markerPosition, width: width))
                        .zIndex(1)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(percentLeft)) percent remaining")
    }

    /// Normalized expected remaining capacity, suitable for a horizontal
    /// position in the bar. `nil` deliberately means no marker should render.
    static func markerPosition(percentLeft: Double, paceDelta: Double?) -> Double? {
        expectedRemaining(percentLeft: percentLeft, paceDelta: paceDelta).map { $0 / 100 }
    }

    private static func clampedFraction(_ percent: Double) -> Double {
        min(max(percent / 100, 0), 1)
    }

    private static func markerOffset(_ position: Double, width: Double) -> Double {
        min(
            max(position * width - Double(markerWidth / 2), 0),
            max(width - Double(markerWidth), 0)
        )
    }
}
