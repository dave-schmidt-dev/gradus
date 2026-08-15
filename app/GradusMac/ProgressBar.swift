import GradusKit
import SwiftUI

/// Hand-drawn in place of `ProgressView`: the native control is AppKit-
/// representable-backed and doesn't rasterize under `ImageRenderer`
/// offscreen. A plain `Capsule` fill renders identically in the live app
/// and under the snapshot gate.
struct ProgressBar: View {
    private static let markerWidth: CGFloat = 3

    let fraction: Double
    let markerFraction: Double?
    let tint: Color

    /// The marker stays inside the bar. A marker taller than its bar made rows
    /// with a pace reference appear visually thicker than rows without one.
    static func markerOverhang(barHeight _: CGFloat) -> CGFloat {
        0
    }

    /// The expected-remaining marker uses the shared kit calculation so the
    /// compact Mac row stays aligned with the other Gradus surfaces.
    static func expectedRemainingMarkerFraction(
        percentLeft: Double?,
        paceDelta: Double?
    ) -> Double? {
        expectedRemaining(percentLeft: percentLeft, paceDelta: paceDelta).map { $0 / 100 }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(tint)
                    .frame(width: geometry.size.width * max(0, min(1, fraction)))
                if let markerFraction {
                    Rectangle()
                        .fill(SignalColor.paceMarker)
                        .frame(width: Self.markerWidth, height: geometry.size.height)
                        .offset(
                            x: markerOffset(
                                fraction: markerFraction,
                                barWidth: geometry.size.width,
                                markerWidth: Self.markerWidth
                            )
                        )
                        .zIndex(1)
                        .accessibilityLabel("Expected remaining")
                }
            }
        }
    }
}
