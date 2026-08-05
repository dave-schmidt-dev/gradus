import GradusKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import GradusiOS

// P2/T2.2 gate: hero/compact x ok/error `StatTile` snapshots, light+dark,
// following `DashboardSnapshotTests.swift`'s exact `.image(layout: .fixed)`
// pattern. The error/nil-`selectedWindow` cases matter most here (per the
// task): they're a real reachable state (Phase 3's OW-1 ranking fix can
// rank an errored provider as hero) and must match `ProviderCard.swift`'s
// existing error-branch styling in both sizes.

private let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)

private func okProvider() -> ProviderStatus {
    ProviderStatus(
        providerName: "codex",
        providerDisplayName: "Codex",
        ok: true,
        errorMessage: nil,
        windows: [
            ProviderWindow(
                id: "weekly", percentLeft: 62, resetISO: "2026-08-08T05:00:00-04:00", windowHours: 168,
                paceDelta: -0.05),
            ProviderWindow(
                id: "five_hour", percentLeft: 88, resetISO: "2026-08-03T01:00:00-04:00", windowHours: 5,
                paceDelta: 0.02),
        ],
        data: [:],
        observedAt: ISO8601DateFormatter().string(from: fixedNow),
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

private func noWindowDataProvider() -> ProviderStatus {
    ProviderStatus(
        providerName: "vibe",
        providerDisplayName: "Vibe",
        ok: true,
        errorMessage: nil,
        windows: [],
        data: [:],
        observedAt: ISO8601DateFormatter().string(from: fixedNow),
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: fixedNow
    )
}

@MainActor
@Test func statTileHeroOkLight() {
    let provider = okProvider()
    let view = StatTile(
        provider: provider, selectedWindow: provider.windows.first,
        badgeWindows: Array(provider.windows.dropFirst()), isHero: true, now: fixedNow)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 220), traits: UITraitCollection(userInterfaceStyle: .light)))
}

@MainActor
@Test func statTileHeroOkDark() {
    let provider = okProvider()
    let view = StatTile(
        provider: provider, selectedWindow: provider.windows.first,
        badgeWindows: Array(provider.windows.dropFirst()), isHero: true, now: fixedNow)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 220), traits: UITraitCollection(userInterfaceStyle: .dark)))
}

@MainActor
@Test func statTileHeroErrorLight() {
    let provider = erroredProvider()
    let view = StatTile(provider: provider, selectedWindow: nil, isHero: true, now: fixedNow)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 120), traits: UITraitCollection(userInterfaceStyle: .light)))
}

@MainActor
@Test func statTileHeroErrorDark() {
    let provider = erroredProvider()
    let view = StatTile(provider: provider, selectedWindow: nil, isHero: true, now: fixedNow)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 120), traits: UITraitCollection(userInterfaceStyle: .dark)))
}

@MainActor
@Test func statTileCompactOkLight() {
    let provider = okProvider()
    let view = StatTile(
        provider: provider, selectedWindow: provider.windows.first,
        badgeWindows: Array(provider.windows.dropFirst()), isHero: false, now: fixedNow)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 100), traits: UITraitCollection(userInterfaceStyle: .light)))
}

@MainActor
@Test func statTileCompactOkDark() {
    let provider = okProvider()
    let view = StatTile(
        provider: provider, selectedWindow: provider.windows.first,
        badgeWindows: Array(provider.windows.dropFirst()), isHero: false, now: fixedNow)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 100), traits: UITraitCollection(userInterfaceStyle: .dark)))
}

@MainActor
@Test func statTileCompactErrorLight() {
    let provider = erroredProvider()
    let view = StatTile(provider: provider, selectedWindow: nil, isHero: false, now: fixedNow)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 80), traits: UITraitCollection(userInterfaceStyle: .light)))
}

@MainActor
@Test func statTileCompactErrorDark() {
    let provider = erroredProvider()
    let view = StatTile(provider: provider, selectedWindow: nil, isHero: false, now: fixedNow)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 80), traits: UITraitCollection(userInterfaceStyle: .dark)))
}

// Bonus coverage beyond the 4-combination minimum: `provider.ok == true`
// with an empty `windows` array is a distinct nil-`selectedWindow` sub-case
// (ProviderCard.swift's "no window data" branch) from the errored one
// above -- confirms StatTile's error variant is a genuine superset of
// ProviderCard's three-way branch, not just the two-way ok/error split.
@MainActor
@Test func statTileCompactNoWindowDataLight() {
    let provider = noWindowDataProvider()
    let view = StatTile(provider: provider, selectedWindow: nil, isHero: false, now: fixedNow)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 80), traits: UITraitCollection(userInterfaceStyle: .light)))
}

// Local urgency no longer changes a tile's presentation. These retain the
// prior snapshot names to prove the old cyan overlay and extra padding are
// absent for the former local-urgent fixtures.

@MainActor
@Test func statTileCompactLocallyUrgentLight() {
    let provider = okProvider()
    let view = StatTile(provider: provider, selectedWindow: provider.windows.first, isHero: false, now: fixedNow)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 100), traits: UITraitCollection(userInterfaceStyle: .light)))
}

@MainActor
@Test func statTileCompactLocallyUrgentDark() {
    let provider = okProvider()
    let view = StatTile(provider: provider, selectedWindow: provider.windows.first, isHero: false, now: fixedNow)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 100), traits: UITraitCollection(userInterfaceStyle: .dark)))
}

@MainActor
@Test func statTileHeroLocallyUrgentLight() {
    let provider = okProvider()
    let view = StatTile(provider: provider, selectedWindow: provider.windows.first, isHero: true, now: fixedNow)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 220), traits: UITraitCollection(userInterfaceStyle: .light)))
}

@Test func usageBarPlacesAndOmitsExpectedPaceMarker() {
    #expect(UsageBar.markerPosition(percentLeft: 62, paceDelta: -0.05) == 0.67)
    #expect(UsageBar.markerPosition(percentLeft: 62, paceDelta: nil) == nil)
    #expect(UsageBar.markerPosition(percentLeft: 62, paceDelta: .infinity) == nil)
    #expect(UsageBar.markerPosition(percentLeft: 101, paceDelta: -0.05) == nil)
}
