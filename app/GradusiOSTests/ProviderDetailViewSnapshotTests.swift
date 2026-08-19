@testable import GradusiOS
import GradusKit
import SnapshotTesting
import SwiftUI
import Testing

// P4/T4.2 gate: `ProviderDetailView` renders every window in
// `provider.windows`, not just the worst one -- so this needs a
// multi-window fixture provider. None of `DashboardSnapshotTests.swift`'s
// `sampleProviders()` has more than one window, and that fixture is shared
// with already-baselined Phase 3 snapshots, so this file defines its own
// dedicated multi-window fixture rather than extending the shared one.

private let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)

/// Opt in only while intentionally refreshing the carried-failure baseline:
/// OTHER_SWIFT_FLAGS='$(inherited) -D PROVIDER_DETAIL_SNAPSHOT_RECORD'
private let providerDetailSnapshotRecording: SnapshotTestingConfiguration.Record = {
    #if PROVIDER_DETAIL_SNAPSHOT_RECORD
        return .all
    #else
        return .never
    #endif
}()

private func multiWindowProvider() -> ProviderStatus {
    ProviderStatus(
        providerName: "opencode-go",
        providerDisplayName: "OpenCode Go",
        ok: true,
        errorMessage: nil,
        windows: [
            ProviderWindow(
                id: "five_hour", percentLeft: 82, resetISO: "2026-08-03T01:00:00-04:00", windowHours: 5,
                paceDelta: 0.02
            ),
            ProviderWindow(
                id: "weekly", percentLeft: 47, resetISO: "2026-08-08T05:00:00-04:00", windowHours: 168,
                paceDelta: -0.08
            ),
            ProviderWindow(
                id: "monthly", percentLeft: 15, resetISO: "2026-08-30T05:00:00-04:00", windowHours: 720,
                paceDelta: -0.15
            )
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
        errorMessage: "Claude session expired: sign in at claude.ai",
        windows: [
            ProviderWindow(
                id: "five_hour", percentLeft: 62, resetISO: "2026-08-03T01:00:00-04:00",
                windowHours: 5, paceDelta: -0.05
            )
        ],
        data: [:],
        observedAt: ISO8601DateFormatter().string(from: fixedNow.addingTimeInterval(-600)),
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: fixedNow
    )
}

@MainActor
@Test func providerDetailRendersAllWindowsLight() {
    let view = ProviderDetailView(provider: multiWindowProvider(), now: fixedNow)
    assertSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 620), traits: UITraitCollection(userInterfaceStyle: .light)),
        record: providerDetailSnapshotRecording
    )
}

@MainActor
@Test func providerDetailRendersAllWindowsDark() {
    let view = ProviderDetailView(provider: multiWindowProvider(), now: fixedNow)
    assertSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 620), traits: UITraitCollection(userInterfaceStyle: .dark)),
        record: providerDetailSnapshotRecording
    )
}

@MainActor
@Test func providerDetailRendersErrorStateLight() {
    let view = ProviderDetailView(provider: erroredProvider(), now: fixedNow)
    assertSnapshot(
        of: view,
        as: .image(layout: .fixed(width: 390, height: 360), traits: UITraitCollection(userInterfaceStyle: .light)),
        record: providerDetailSnapshotRecording
    )
}
