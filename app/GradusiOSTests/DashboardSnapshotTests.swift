import GradusKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import GradusiOS

// T3.5 gate: swift-snapshot-testing regression for the populated dashboard
// (light + dark) and each of the three distinct empty states (CV-5). These
// render `DashboardView`/`EmptyStateView` directly from seeded fixture data
// -- no live CloudKit, no `XCUIApplication` -- mirroring how the Mac side
// snapshots `ProviderListView` standalone (T2b.4). Lives in `GradusiOSTests`
// (a real unit-test bundle), not `GradusiOSUITests` -- a `bundle.ui-testing`
// target doesn't link against the app's compiled code at all, so
// `@testable import GradusiOS` type-checks there but fails at link time.

private let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)  // 2026-08-02T20:00:00-04:00-ish, matches fixture below

private func sampleProviders() -> [ProviderStatus] {
    [
        ProviderStatus(
            providerName: "codex",
            providerDisplayName: "Codex",
            ok: true,
            errorMessage: nil,
            windows: [
                ProviderWindow(
                    id: "weekly", percentLeft: 62, resetISO: "2026-08-08T05:00:00-04:00", windowHours: 168,
                    paceDelta: -0.05)
            ],
            data: [:],
            observedAt: ISO8601DateFormatter().string(from: fixedNow.addingTimeInterval(-30)),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: fixedNow
        ),
        ProviderStatus(
            providerName: "antigravity-claude",
            providerDisplayName: "Antigravity (Claude)",
            ok: true,
            errorMessage: nil,
            windows: [
                ProviderWindow(
                    id: "weekly", percentLeft: 4, resetISO: "2026-08-05T00:00:00-04:00", windowHours: 168,
                    paceDelta: -0.30)
            ],
            data: [:],
            // Carried-forward and stale: > staleThresholdSeconds old (T3.4/CR-1).
            observedAt: ISO8601DateFormatter().string(from: fixedNow.addingTimeInterval(-900)),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: fixedNow
        ),
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
        ),
    ]
}

@MainActor
private func makeViewModel(providers: [ProviderStatus]) -> DashboardViewModel {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
    let cache = FileLocalCacheStore(directory: directory)
    try? cache.saveCachedStatuses(providers, syncedAt: fixedNow)
    return DashboardViewModel(cache: cache)
}

@MainActor
@Test func dashboardRendersPopulatedCardsLight() {
    let viewModel = makeViewModel(providers: sampleProviders())
    let view = DashboardView(viewModel: viewModel, now: fixedNow)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 500), traits: UITraitCollection(userInterfaceStyle: .light)))
}

@MainActor
@Test func dashboardRendersPopulatedCardsDark() {
    let viewModel = makeViewModel(providers: sampleProviders())
    let view = DashboardView(viewModel: viewModel, now: fixedNow)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 500), traits: UITraitCollection(userInterfaceStyle: .dark)))
}

@MainActor
@Test func emptyStateNotSignedIn() {
    let view = EmptyStateView(state: .notSignedIn)
    assertSnapshot(of: view, as: .image(layout: .fixed(width: 390, height: 400)))
}

@MainActor
@Test func emptyStateSyncDisabled() {
    let view = EmptyStateView(state: .syncDisabled)
    assertSnapshot(of: view, as: .image(layout: .fixed(width: 390, height: 400)))
}

@MainActor
@Test func emptyStateWaitingForFirstPublish() {
    let view = EmptyStateView(state: .waitingForFirstPublish)
    assertSnapshot(of: view, as: .image(layout: .fixed(width: 390, height: 400)))
}
