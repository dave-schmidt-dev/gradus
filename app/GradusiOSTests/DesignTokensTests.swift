import SwiftUI
import Testing
import UIKit

@testable import GradusiOS

// P1/T1.1 gate: `SignalColor.forPercent` boundary behavior against the
// four-tier urgency ramp (>=70 green, >=40 yellow, >=20 orange, else red),
// mirroring the TUI's `_style_for_percent` thresholds (`gradus/ui.py`).
// Colors are compared via their resolved sRGB `UIColor` components rather
// than `Color` equality, since deployment target 16 predates
// `Color.resolve(in:)` (iOS 17+).

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

@Test func signalColorJustBelowSeventyIsYellow() {
    expectSameColor(SignalColor.forPercent(69.9), Color(hex: 0xFFD75F))
}

@Test func signalColorAtSeventyIsGreen() {
    expectSameColor(SignalColor.forPercent(70), Color(hex: 0x87D787))
}

@Test func signalColorJustBelowFortyIsOrange() {
    expectSameColor(SignalColor.forPercent(39.9), Color(hex: 0xFFAF5F))
}

@Test func signalColorAtFortyIsYellow() {
    expectSameColor(SignalColor.forPercent(40), Color(hex: 0xFFD75F))
}

@Test func signalColorJustBelowTwentyIsRed() {
    expectSameColor(SignalColor.forPercent(19.9), Color(hex: 0xFF5F5F))
}

@Test func signalColorAtTwentyIsOrange() {
    expectSameColor(SignalColor.forPercent(20), Color(hex: 0xFFAF5F))
}
