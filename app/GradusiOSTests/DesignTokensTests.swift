@testable import GradusiOS
import GradusKit
import SwiftUI
import Testing
import UIKit

// `SignalColor` is now only the SwiftUI rendering of `GradusKit.SignalLevel` --
// the classification itself is tested against the shared cross-language truth
// table in `GradusKitTests/SignalLevelTests.swift`. What is left to prove here
// is that each level maps to the right pixels, including the two cases the
// pure classifier cannot express: `.unknown` rendering muted, and pace
// overriding percentage on a real window.
//
// Colors are compared via their resolved sRGB `UIColor` components rather
// than `Color` equality, since deployment target 16 predates
// `Color.resolve(in:)` (iOS 17+).

private func window(percentLeft: Double, paceDelta: Double?) -> ProviderWindow {
    ProviderWindow(
        id: "five_hour", percentLeft: percentLeft, resetISO: nil,
        windowHours: 5, paceDelta: paceDelta
    )
}

private func rgbComponents(_ color: Color) -> (red: Double, green: Double, blue: Double) {
    let uiColor = UIColor(color)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return (Double(red), Double(green), Double(blue))
}

private func expectSameColor(_ lhs: Color, _ rhs: Color, sourceLocation: SourceLocation = #_sourceLocation) {
    let lhsComponents = rgbComponents(lhs)
    let rhsComponents = rgbComponents(rhs)
    #expect(abs(lhsComponents.red - rhsComponents.red) < 0.001, sourceLocation: sourceLocation)
    #expect(abs(lhsComponents.green - rhsComponents.green) < 0.001, sourceLocation: sourceLocation)
    #expect(abs(lhsComponents.blue - rhsComponents.blue) < 0.001, sourceLocation: sourceLocation)
}

@Test func hexInitializerExpandsByteTriplet() {
    let color = Color(hex: 0x87D787)
    let components = rgbComponents(color)
    #expect(abs(components.red - Double(0x87) / 255) < 0.001)
    #expect(abs(components.green - Double(0xD7) / 255) < 0.001)
    #expect(abs(components.blue - Double(0x87) / 255) < 0.001)
}

@Test func everyLevelRendersItsCanonicalHex() {
    expectSameColor(SignalColor.forLevel(.green), Color(hex: 0x87D787))
    expectSameColor(SignalColor.forLevel(.yellow), Color(hex: 0xFFD75F))
    expectSameColor(SignalColor.forLevel(.orange), Color(hex: 0xFFAF5F))
    expectSameColor(SignalColor.forLevel(.red), Color(hex: 0xFF5F5F))
}

/// An invalid percentage must not borrow a ramp color. Before the pace ramp,
/// `forPercent(150)` returned green -- an INV-3 violation rendered as "healthy".
@Test func unknownLevelRendersMutedRatherThanAnyRampColor() {
    expectSameColor(SignalColor.forLevel(.unknown), .secondary)
    expectSameColor(SignalColor.forWindow(window(percentLeft: 150, paceDelta: nil)), .secondary)
    expectSameColor(SignalColor.forWindow(window(percentLeft: -5, paceDelta: nil)), .secondary)
}

/// Windows carrying no pace fall back to the percent ramp, so the original
/// P1/T1.1 boundaries still hold on that path.
@Test func windowsWithoutPaceKeepThePercentBoundaries() {
    expectSameColor(SignalColor.forWindow(window(percentLeft: 70, paceDelta: nil)), Color(hex: 0x87D787))
    expectSameColor(SignalColor.forWindow(window(percentLeft: 69.9, paceDelta: nil)), Color(hex: 0xFFD75F))
    expectSameColor(SignalColor.forWindow(window(percentLeft: 40, paceDelta: nil)), Color(hex: 0xFFD75F))
    expectSameColor(SignalColor.forWindow(window(percentLeft: 39.9, paceDelta: nil)), Color(hex: 0xFFAF5F))
    expectSameColor(SignalColor.forWindow(window(percentLeft: 20, paceDelta: nil)), Color(hex: 0xFFAF5F))
    expectSameColor(SignalColor.forWindow(window(percentLeft: 19.9, paceDelta: nil)), Color(hex: 0xFF5F5F))
}

/// The behavior change, stated as pixels: identical percentages render
/// differently once pace is known.
@Test func paceOverridesPercentageWhenAvailable() {
    // 1% left five minutes before a 5-hour reset: on pace, not an emergency.
    expectSameColor(SignalColor.forWindow(window(percentLeft: 1, paceDelta: -0.0067)), Color(hex: 0xFFD75F))
    // Same 1%, but with most of the window still to run: genuinely spent.
    expectSameColor(SignalColor.forWindow(window(percentLeft: 1, paceDelta: -0.9)), Color(hex: 0xFF5F5F))
    // 20% left with 80% of the window remaining -- the percent ramp said orange.
    expectSameColor(SignalColor.forWindow(window(percentLeft: 20, paceDelta: -0.6)), Color(hex: 0xFF5F5F))
    // 50% left five minutes before reset -- the percent ramp said yellow.
    expectSameColor(SignalColor.forWindow(window(percentLeft: 50, paceDelta: 0.483)), Color(hex: 0x87D787))
}

/// Depletion outranks pace: exhausted is exhausted.
@Test func depletedWindowIsRedRegardlessOfPace() {
    expectSameColor(SignalColor.forWindow(window(percentLeft: 0, paceDelta: 0.9)), Color(hex: 0xFF5F5F))
}
