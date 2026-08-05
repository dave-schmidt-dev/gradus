import GradusKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import GradusiOS

// Pixel coverage for iPad Option B at real device point sizes, with the full
// provider set. The existing dashboard snapshots are 390x600 -- an iPhone
// viewport -- so nothing in the suite would have shown an iPad regression.
//
// David's original complaint was that he has to scroll to see all his
// providers. That is a claim about a specific device size with a specific
// number of providers, so these fixtures use the real count (8 providers, 14
// windows) at real iPad dimensions rather than a reduced sample. A fixture of
// three providers would fit any layout and prove nothing.

private let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)

/// Every provider in David's actual set, with the window shape each really
/// has (Cursor two pools, Antigravity's split Gemini/Claude quotas, Copilot
/// premium-only, Vibe on a billing cycle).
@MainActor
private func fullProviderSet() -> [ProviderStatus] {
    func w(_ id: String, _ percent: Double, _ pace: Double?, _ reset: String?) -> ProviderWindow {
        ProviderWindow(id: id, percentLeft: percent, resetISO: reset, windowHours: 168, paceDelta: pace)
    }
    func p(_ name: String, _ display: String, _ windows: [ProviderWindow]) -> ProviderStatus {
        ProviderStatus(
            providerName: name, providerDisplayName: display, ok: true, errorMessage: nil,
            windows: windows, data: [:],
            observedAt: ISO8601DateFormatter().string(from: fixedNow),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00", publishedAt: fixedNow,
            syncSource: name == "opencode"
                ? SyncSource(computerName: "dm5mbp", userName: "dave") : nil)
    }
    return [
        p("opencode", "OpenCode Go", [
            w("five_hour", 100, 0.30, "2026-07-25T15:05:00-04:00"),
            w("monthly", 7, -0.42, "2026-08-23T21:30:00-04:00"),
            w("weekly", 61, -0.12, "2026-08-01T20:00:00-04:00"),
        ]),
        p("codex", "Codex", [w("weekly", 76, -0.05, "2026-07-28T09:19:00-04:00")]),
        p("antigravity", "Antigravity", [
            w("five_hour", 100, 0.22, "2026-07-25T15:00:00-04:00"),
            w("weekly", 80, 0.04, "2026-07-28T14:16:00-04:00"),
        ]),
        p("claude", "Claude", [
            w("five_hour", 97, 0.18, "2026-07-25T15:00:00-04:00"),
            w("weekly", 99, 0.31, "2026-07-28T21:59:00-04:00"),
        ]),
        p("copilot", "Copilot", [w("premium", 100, 0.44, "2026-08-31T20:00:00-04:00")]),
        p("vibe", "Vibe", [w("billing_cycle", 100, 0.51, "2026-09-01T00:00:00-04:00")]),
        p("antigravity-claude", "Antigravity (Claude)", [
            w("five_hour", 100, 0.28, "2026-07-25T15:24:00-04:00"),
            w("weekly", 0, -0.60, "2026-07-25T13:26:00-04:00"),
        ]),
        // Cursor's real schema-v2 pool ids are "ap"/"ac", not "api"/"auto" --
        // see ProviderWindowLabel. Using the wrong ids here would have quietly
        // exercised the raw-id fallback instead of the real label mapping.
        p("cursor", "Cursor", [
            w("ap", 0, -0.55, "2026-08-12T07:46:00-04:00"),
            w("ac", 0, -0.55, "2026-08-12T07:46:00-04:00"),
        ]),
    ]
}

@MainActor
private func makeViewModel() -> DashboardViewModel {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-density-snap-\(UUID().uuidString)", isDirectory: true)
    let cache = FileLocalCacheStore(directory: directory)
    let defaults = UserDefaults(suiteName: "gradus-density-snap-\(UUID().uuidString)")!
    defaults.set(true, forKey: DashboardViewModel.showExhaustedKey)
    try? cache.saveCachedStatuses(fullProviderSet(), syncedAt: fixedNow)
    return DashboardViewModel(cache: cache, userDefaults: defaults)
}

@MainActor
private func denseDashboard() -> some View {
    DashboardContent(viewModel: makeViewModel(), now: fixedNow, layout: .denseGrid)
}

// iPad 11" portrait. Two columns at this width; all 8 providers and all 14
// windows are on screen at once, which is the whole point of Option B.
@MainActor
@Test func densePadPortraitLight() {
    assertSnapshot(
        of: denseDashboard(),
        as: .image(
            layout: .fixed(width: 834, height: 1194),
            traits: UITraitCollection(userInterfaceStyle: .light)),
        testName: "densePadPortraitLight")
}

@MainActor
@Test func densePadPortraitDark() {
    assertSnapshot(
        of: denseDashboard(),
        as: .image(
            layout: .fixed(width: 834, height: 1194),
            traits: UITraitCollection(userInterfaceStyle: .dark)),
        testName: "densePadPortraitDark")
}

// Landscape has room for a third column. Fixed two-column layouts stretch
// cards across the full width, which is the wasted horizontal space this
// layout exists to remove -- so the column count must actually change here.
@MainActor
@Test func densePadLandscapeDark() {
    assertSnapshot(
        of: denseDashboard(),
        as: .image(
            layout: .fixed(width: 1194, height: 834),
            traits: UITraitCollection(userInterfaceStyle: .dark)),
        testName: "densePadLandscapeDark")
}
