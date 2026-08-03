import GradusKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import GradusiOS

// P4/T4.2 gate: `ProviderDetailView` renders every window in
// `provider.windows`, not just the worst one -- so this needs a
// multi-window fixture provider. None of `DashboardSnapshotTests.swift`'s
// `sampleProviders()` has more than one window, and that fixture is shared
// with already-baselined Phase 3 snapshots, so this file defines its own
// dedicated multi-window fixture rather than extending the shared one.

private let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)

private func multiWindowProvider() -> ProviderStatus {
    ProviderStatus(
        providerName: "opencode-go",
        providerDisplayName: "OpenCode Go",
        ok: true,
        errorMessage: nil,
        windows: [
            ProviderWindow(
                id: "five_hour", percentLeft: 82, resetISO: "2026-08-03T01:00:00-04:00", windowHours: 5,
                paceDelta: 0.02),
            ProviderWindow(
                id: "weekly", percentLeft: 47, resetISO: "2026-08-08T05:00:00-04:00", windowHours: 168,
                paceDelta: -0.08),
            ProviderWindow(
                id: "monthly", percentLeft: 15, resetISO: "2026-08-30T05:00:00-04:00", windowHours: 720,
                paceDelta: -0.15),
        ],
        data: [:],
        observedAt: ISO8601DateFormatter().string(from: fixedNow.addingTimeInterval(-30)),
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: fixedNow
    )
}

private func erroredProvider() -> ProviderStatus {
    ProviderStatus(
        providerName: "cursor",
        providerDisplayName: "Cursor",
        ok: false,
        errorMessage: "transient fetch failure",
        windows: [],
        data: [:],
        observedAt: nil,
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: fixedNow
    )
}

@MainActor
@Test func providerDetailRendersAllWindowsLight() {
    let view = ProviderDetailView(provider: multiWindowProvider(), now: fixedNow)
    assertSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 620), traits: UITraitCollection(userInterfaceStyle: .light)))
}

@MainActor
@Test func providerDetailRendersAllWindowsDark() {
    let view = ProviderDetailView(provider: multiWindowProvider(), now: fixedNow)
    assertSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 620), traits: UITraitCollection(userInterfaceStyle: .dark)))
}

@MainActor
@Test func providerDetailRendersErrorStateLight() {
    let view = ProviderDetailView(provider: erroredProvider(), now: fixedNow)
    assertSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 200), traits: UITraitCollection(userInterfaceStyle: .light)))
}
