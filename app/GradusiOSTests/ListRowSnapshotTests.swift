@testable import GradusiOS
import SnapshotTesting
import SwiftUI
import Testing

// P2/T2.2 gate: one snapshot per trailing-accessory variant (toggle-on,
// toggle-off, chevron, value-text), light+dark, following
// `DashboardSnapshotTests.swift`'s exact `.image(layout: .fixed)` pattern.

@MainActor
@Test func listRowToggleOnLight() {
    let view = ListRow.toggle(icon: Icon.bell, label: "Notifications", isOn: .constant(true))
    assertSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 44), traits: UITraitCollection(userInterfaceStyle: .light))
    )
}

@MainActor
@Test func listRowToggleOnDark() {
    let view = ListRow.toggle(icon: Icon.bell, label: "Notifications", isOn: .constant(true))
    assertSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 44), traits: UITraitCollection(userInterfaceStyle: .dark))
    )
}

@MainActor
@Test func listRowToggleOffLight() {
    let view = ListRow.toggle(icon: Icon.bell, label: "Notifications", isOn: .constant(false))
    assertSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 44), traits: UITraitCollection(userInterfaceStyle: .light))
    )
}

@MainActor
@Test func listRowToggleOffDark() {
    let view = ListRow.toggle(icon: Icon.bell, label: "Notifications", isOn: .constant(false))
    assertSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 44), traits: UITraitCollection(userInterfaceStyle: .dark))
    )
}

@MainActor
@Test func listRowChevronLight() {
    let view = ListRow.chevron(icon: Icon.settings, label: "Settings")
    assertSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 44), traits: UITraitCollection(userInterfaceStyle: .light))
    )
}

@MainActor
@Test func listRowChevronDark() {
    let view = ListRow.chevron(icon: Icon.settings, label: "Settings")
    assertSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 44), traits: UITraitCollection(userInterfaceStyle: .dark))
    )
}

@MainActor
@Test func listRowValueLight() {
    let view = ListRow.value(icon: Icon.infoCircle, label: "Version", value: "1.1 (3)")
    assertSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 44), traits: UITraitCollection(userInterfaceStyle: .light))
    )
}

@MainActor
@Test func listRowValueDark() {
    let view = ListRow.value(icon: Icon.infoCircle, label: "Version", value: "1.1 (3)")
    assertSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 44), traits: UITraitCollection(userInterfaceStyle: .dark))
    )
}
