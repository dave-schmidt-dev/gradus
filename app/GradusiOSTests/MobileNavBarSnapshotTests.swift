@testable import GradusiOS
import SnapshotTesting
import SwiftUI
import Testing

// P2/T2.3 gate: title + one trailing `IconButton`, light+dark, following
// `DashboardSnapshotTests.swift`'s exact `.image(layout: .fixed)` pattern.

@MainActor
@Test func mobileNavBarTitleWithTrailingIconButtonLight() {
    let view = MobileNavBar(title: "Gradus") {
        IconButton(Icon.settings) {}
    }
    assertIOSSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 56), traits: UITraitCollection(userInterfaceStyle: .light))
    )
}

@MainActor
@Test func mobileNavBarTitleWithTrailingIconButtonDark() {
    let view = MobileNavBar(title: "Gradus") {
        IconButton(Icon.settings) {}
    }
    assertIOSSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 56), traits: UITraitCollection(userInterfaceStyle: .dark))
    )
}
