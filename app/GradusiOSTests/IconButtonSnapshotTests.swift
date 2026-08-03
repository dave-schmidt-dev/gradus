import SnapshotTesting
import SwiftUI
import Testing
import UIKit

@testable import GradusiOS

// P2/T2.4 gate: confirms the rendered tap target is >= 44x44pt regardless
// of the icon glyph's intrinsic size -- via `UIHostingController`'s actual
// layout (`sizeThatFits(in:)`, iOS 16+), not just eyeballing a snapshot --
// plus a fixed 44x44 snapshot (light+dark) showing the glyph centered
// inside that frame, following `DashboardSnapshotTests.swift`'s exact
// `.image(layout: .fixed)` pattern.

@MainActor
@Test func iconButtonTapTargetIsAtLeast44x44() {
    let button = IconButton(Icon.bell) {}
    let controller = UIHostingController(rootView: button)
    let size = controller.sizeThatFits(in: CGSize(width: 1000, height: 1000))
    #expect(size.width >= 44)
    #expect(size.height >= 44)
}

@MainActor
@Test func iconButtonSmallGlyphStillMeasuresAtLeast44x44() {
    // `chevronLeft` renders a visually tiny glyph -- confirms the >= 44pt
    // floor holds regardless of the icon's intrinsic size, not just for
    // visually large glyphs like `bell`.
    let button = IconButton(Icon.chevronLeft) {}
    let controller = UIHostingController(rootView: button)
    let size = controller.sizeThatFits(in: CGSize(width: 1000, height: 1000))
    #expect(size.width >= 44)
    #expect(size.height >= 44)
}

@MainActor
@Test func iconButtonSnapshotLight() {
    let view = IconButton(Icon.settings) {}
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 44, height: 44), traits: UITraitCollection(userInterfaceStyle: .light)))
}

@MainActor
@Test func iconButtonSnapshotDark() {
    let view = IconButton(Icon.settings) {}
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 44, height: 44), traits: UITraitCollection(userInterfaceStyle: .dark)))
}
