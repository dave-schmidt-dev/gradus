@testable import GradusiOS
import GradusKit
import SnapshotTesting
import SwiftUI
import Testing

// Shared fixtures and helpers for DensityLayoutSnapshotTests, split out here
// to keep that file under SwiftLint's file_length limit. Every `@Test func`
// that calls `assertIOSSnapshot` stays in DensityLayoutSnapshotTests.swift
// itself: test-gate.sh's self-check parses that exact file to derive the
// canonical density image snapshot selectors, so moving one of those
// functions elsewhere would desync the gate from its own source of truth.

let densityLayoutFixedNow = Date(timeIntervalSince1970: 1_785_000_000)

/// Every provider in David's actual set, with the window shape each really
/// has (Cursor two pools, Antigravity's split Gemini/Claude quotas, Copilot
/// monthly, Vibe on a monthly bucket, Codex (Spark) as its own weekly bucket
/// alongside Codex).
@MainActor
func fullProviderSet() -> [ProviderStatus] {
    func w(_ id: String, _ percent: Double, _ pace: Double?, _ reset: String?) -> ProviderWindow {
        ProviderWindow(id: id, percentLeft: percent, resetISO: reset, windowHours: 168, paceDelta: pace)
    }
    func p(_ name: String, _ display: String, _ windows: [ProviderWindow]) -> ProviderStatus {
        ProviderStatus(
            providerName: name, providerDisplayName: display, ok: true, errorMessage: nil,
            windows: windows, data: [:],
            observedAt: ISO8601DateFormatter().string(from: densityLayoutFixedNow),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00", publishedAt: densityLayoutFixedNow,
            syncSource: name == "opencode"
                ? SyncSource(computerName: "dm5mbp", userName: "dave") : nil
        )
    }
    return [
        p("opencode", "OpenCode Go", [
            w("five_hour", 100, 0.30, "2026-07-25T15:05:00-04:00"),
            w("monthly", 7, -0.42, "2026-08-23T21:30:00-04:00"),
            w("weekly", 61, -0.12, "2026-08-01T20:00:00-04:00")
        ]),
        p("codex", "Codex", [w("weekly", 76, -0.05, "2026-07-28T09:19:00-04:00")]),
        p("codex-spark", "Codex (Spark)", [w("weekly", 90, 0.12, "2026-08-08T05:00:00-04:00")]),
        p("antigravity", "Antigravity", [
            w("five_hour", 100, 0.22, "2026-07-25T15:00:00-04:00"),
            w("weekly", 80, 0.04, "2026-07-28T14:16:00-04:00")
        ]),
        p("claude", "Claude", [
            w("five_hour", 97, 0.18, "2026-07-25T15:00:00-04:00"),
            w("weekly", 99, 0.31, "2026-07-28T21:59:00-04:00")
        ]),
        p("copilot", "Copilot", [w("premium", 100, 0.44, "2026-08-31T20:00:00-04:00")]),
        p("vibe", "Vibe", [w("billing_cycle", 100, 0.51, "2026-09-01T00:00:00-04:00")]),
        p("antigravity-claude", "Antigravity (Claude)", [
            w("five_hour", 100, 0.28, "2026-07-25T15:24:00-04:00"),
            w("weekly", 0, -0.60, "2026-07-25T13:26:00-04:00")
        ]),
        // Cursor's real schema-v2 pool ids are "ap"/"ac", not "api"/"auto" --
        // see ProviderWindowLabel. Using the wrong ids here would have quietly
        // exercised the raw-id fallback instead of the real label mapping.
        p("cursor", "Cursor", [
            w("ap", 0, -0.55, "2026-08-12T07:46:00-04:00"),
            w("ac", 0, -0.55, "2026-08-12T07:46:00-04:00")
        ])
    ]
}

let pinnedCardColumnPreference = 1 // Small: the largest feasible count for each width.

let densitySnapshotDisplayScale: CGFloat = 2.0

enum DensitySnapshotFixture {
    case pad
    case phone

    var traits: [UITraitCollection] {
        switch self {
        case .pad:
            [
                UITraitCollection(userInterfaceIdiom: .pad),
                UITraitCollection(horizontalSizeClass: .regular),
                UITraitCollection(verticalSizeClass: .regular)
            ]
        case .phone:
            [
                UITraitCollection(userInterfaceIdiom: .phone),
                UITraitCollection(horizontalSizeClass: .compact),
                UITraitCollection(verticalSizeClass: .regular)
            ]
        }
    }
}

/// Opt in only while intentionally refreshing these baselines:
/// OTHER_SWIFT_FLAGS='$(inherited) -D DENSITY_SNAPSHOT_RECORD'
let densitySnapshotRecording: SnapshotTestingConfiguration.Record = {
    #if DENSITY_SNAPSHOT_RECORD
        return .all
    #else
        return .never
    #endif
}()

func densitySnapshotTraits(
    fixture: DensitySnapshotFixture,
    style: UIUserInterfaceStyle,
    contentSizeCategory: UIContentSizeCategory? = nil
) -> UITraitCollection {
    var traits = fixture.traits + [
        UITraitCollection(displayScale: densitySnapshotDisplayScale),
        UITraitCollection(userInterfaceStyle: style)
    ]
    if let contentSizeCategory {
        traits.append(UITraitCollection(preferredContentSizeCategory: contentSizeCategory))
    }
    return UITraitCollection(traitsFrom: traits)
}

@MainActor
func makeViewModel() -> DashboardViewModel {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-density-snap-\(UUID().uuidString)", isDirectory: true)
    let cache = FileLocalCacheStore(directory: directory)
    let defaults = UserDefaults(suiteName: "gradus-density-snap-\(UUID().uuidString)")!
    defaults.set(true, forKey: DashboardViewModel.showExhaustedKey)
    defaults.set(pinnedCardColumnPreference, forKey: DashboardViewModel.cardColumnPreferenceKey)
    let providers = fullProviderSet()
    let windows = providers.flatMap(\.windows)
    #expect(windows.contains { ($0.paceDelta ?? 0) > 0 })
    #expect(windows.contains { ($0.paceDelta ?? 0) < 0 })
    #expect(windows.contains { $0.percentLeft == 0 })
    #expect(windows.contains { $0.percentLeft == 100 })
    try? cache.saveCachedStatuses(providers, syncedAt: densityLayoutFixedNow)
    let viewModel = DashboardViewModel(cache: cache, userDefaults: defaults)
    // The initializer treats an unversioned stored value as a legacy direct
    // column count. Set the current slider stop after initialization so every
    // snapshot actually exercises the pinned candidate rather than Auto.
    viewModel.cardColumnPreference = pinnedCardColumnPreference
    return viewModel
}

@MainActor
func denseDashboard(density: DashboardDensity? = nil) -> some View {
    DashboardContent(
        viewModel: makeViewModel(), now: densityLayoutFixedNow, layout: .denseGrid, density: density
    )
}
