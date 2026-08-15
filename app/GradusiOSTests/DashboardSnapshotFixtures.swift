@testable import GradusiOS
import GradusKit
import SnapshotTesting
import XCTest

// Shared fixtures and helpers for the DashboardSnapshotTests suite, split
// across this file, DashboardSnapshotTests.swift,
// DashboardSnapshotTests+SampleData.swift, and
// DashboardSnapshotTests+EmptyStates.swift to keep each file under
// SwiftLint's file_length limit. See DashboardSnapshotTests.swift for the
// suite's overall rationale (T3.5 gate).

/// Matches SampleData.json publication timestamp.
let dashboardSnapshotFixedNow = Date(timeIntervalSince1970: 1_786_219_200)

/// Opt in only while intentionally refreshing these baselines:
/// OTHER_SWIFT_FLAGS='$(inherited) -D DASHBOARD_SNAPSHOT_RECORD'
let dashboardSnapshotRecording: SnapshotTestingConfiguration.Record = {
    #if DASHBOARD_SNAPSHOT_RECORD
        return .all
    #else
        return .never
    #endif
}()

/// Named `dashboardSampleProviders` (not `sampleProviders`) because several
/// other test files in this target each declare their own file-private
/// `sampleProviders()` fixture; this one must stay distinct now that it's
/// visible module-wide.
func dashboardSampleProviders() -> [ProviderStatus] {
    [
        ProviderStatus(
            providerName: "codex",
            providerDisplayName: "Codex",
            ok: true,
            errorMessage: nil,
            windows: [
                ProviderWindow(
                    id: "weekly", percentLeft: 62, resetISO: "2026-08-08T05:00:00-04:00", windowHours: 168,
                    paceDelta: -0.05
                )
            ],
            data: [:],
            observedAt: ISO8601DateFormatter().string(from: dashboardSnapshotFixedNow.addingTimeInterval(-30)),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: dashboardSnapshotFixedNow,
            syncSource: SyncSource(computerName: "Dave's MacBook Pro", userName: "dave")
        ),
        ProviderStatus(
            providerName: "antigravity-claude",
            providerDisplayName: "Antigravity (Claude)",
            ok: true,
            errorMessage: nil,
            windows: [
                ProviderWindow(
                    id: "weekly", percentLeft: 4, resetISO: "2026-08-05T00:00:00-04:00", windowHours: 168,
                    paceDelta: -0.30
                )
            ],
            data: [:],
            // Carried-forward and stale: > staleThresholdSeconds old (T3.4/CR-1).
            observedAt: ISO8601DateFormatter().string(from: dashboardSnapshotFixedNow.addingTimeInterval(-900)),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: dashboardSnapshotFixedNow
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
            publishedAt: dashboardSnapshotFixedNow
        )
    ]
}

func assertSampleProviders(_ providers: [ProviderStatus]) {
    XCTAssertEqual(providers.count, 3)
    XCTAssertTrue(providers.contains { $0.ok && !$0.windows.isEmpty })
    XCTAssertTrue(providers.contains { !$0.ok && $0.windows.isEmpty })
}

func bundledSampleProviders() throws -> [ProviderStatus] {
    try SampleDataMode.bundledProviders(bundle: Bundle(for: AppDelegate.self))
}

@MainActor
func makeViewModel(providers: [ProviderStatus], showExhausted: Bool = true) -> DashboardViewModel {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
    let cache = FileLocalCacheStore(directory: directory)
    let defaults = UserDefaults(suiteName: "gradus-dashboard-snapshots-\(UUID().uuidString)")!
    defaults.set(showExhausted, forKey: DashboardViewModel.showExhaustedKey)
    try? cache.saveCachedStatuses(providers, syncedAt: dashboardSnapshotFixedNow)
    return DashboardViewModel(cache: cache, userDefaults: defaults)
}

func exhaustedProvider(named name: String) -> ProviderStatus {
    ProviderStatus(
        providerName: name,
        providerDisplayName: name.capitalized,
        ok: true,
        errorMessage: nil,
        windows: [
            ProviderWindow(
                id: "weekly", percentLeft: 0, resetISO: "2026-08-05T00:00:00-04:00", windowHours: 168,
                paceDelta: -0.30
            )
        ],
        data: [:],
        observedAt: ISO8601DateFormatter().string(from: dashboardSnapshotFixedNow),
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: dashboardSnapshotFixedNow
    )
}

/// Fixtures whose *displayed number* differs under truncation and rounding, so
/// a dashboard rendered with the old `Int(window.percentLeft)` cannot match
/// this file's baseline.
///
/// Every other percentage in the image suite is a whole number. Those below
/// ten (0, 1, 3, 4, 5) do move -- they gain a decimal -- so a wholesale revert
/// to `Int()` would be caught without this fixture. What no whole number can
/// catch is the defect TASKS row 29 actually described: truncation versus
/// rounding at or above ten, where `Int(47)` and `round(47)` agree and only a
/// fractional value disagrees. `47.8` is that value.
/// Each reset time is derived from its pace rather than picked, on the same
/// `paceDelta == fractionLeft - fractionOfWindowRemaining` identity
/// `paceDivergentProviders` uses -- a fixture whose pace contradicts its own
/// clock would be unreachable in production and a bad thing to pin pixels to.
func truncationDivergentProviders() -> [ProviderStatus] {
    func provider(_ name: String, percentLeft: Double, paceDelta: Double, resetISO: String)
        -> ProviderStatus {
        ProviderStatus(
            providerName: name,
            providerDisplayName: name.capitalized,
            ok: true,
            errorMessage: nil,
            windows: [
                ProviderWindow(
                    id: "weekly", percentLeft: percentLeft, resetISO: resetISO,
                    windowHours: 168, paceDelta: paceDelta
                )
            ],
            data: [:],
            observedAt: ISO8601DateFormatter().string(from: dashboardSnapshotFixedNow),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: dashboardSnapshotFixedNow
        )
    }
    return [
        // Rounds to 48, truncates to 47 -- the value David saw disagree
        // between the TUI and the phone.
        provider(
            "codex", percentLeft: 47.8, paceDelta: -0.05, resetISO: "2026-07-29T06:02:14-04:00"
        ),
        // Rounds up across the decimal band to "10.0", truncates to "9.9".
        provider(
            "cursor", percentLeft: 9.97, paceDelta: -0.12, resetISO: "2026-07-27T02:14:34-04:00"
        ),
        // The one that matters most: above the 0.5 depleted ceiling, so this
        // is a LIVE window, but `Int(0.7)` is 0 -- it rendered, and spoke to
        // VoiceOver, as fully exhausted.
        provider(
            "copilot", percentLeft: 0.7, paceDelta: -0.30, resetISO: "2026-07-27T16:54:33-04:00"
        )
    ]
}

/// Fixtures whose signal level is the *opposite* of what the pre-pace,
/// percent-only ramp produced, so a dashboard rendered with the old ramp
/// cannot match this file's baseline.
///
/// Every other fixture in this file coincidentally agrees under both ramps
/// (62%/-0.05 is yellow either way; 4%/-0.30 and 0%/-0.30 are red either
/// way), which left the dashboard's adoption of the ramp with no pixel
/// coverage at all. These two invert in both directions:
///
/// - `opencode` 3% left, +0.02 pace: nearly empty but the window is nearly
///   over — David's motivating case. Old ramp: red. New: green.
/// - `claude` 72% left, -0.26 pace: plenty left but almost none of the week
///   spent. Old ramp: green. New: red.
///
/// Both are physically reachable: `paceDelta == fractionLeft -
/// fractionOfWindowRemaining`, so the fixtures' reset timestamps are set to
/// the window fraction each pace value implies (1% and 98% of 168h from
/// `dashboardSnapshotFixedNow`) rather than to arbitrary dates that would contradict them.
func paceDivergentProviders() -> [ProviderStatus] {
    [
        ProviderStatus(
            providerName: "opencode",
            providerDisplayName: "OpenCode",
            ok: true,
            errorMessage: nil,
            windows: [
                ProviderWindow(
                    id: "weekly", percentLeft: 3, resetISO: "2026-07-25T15:00:48-04:00", windowHours: 168,
                    paceDelta: 0.02
                )
            ],
            data: [:],
            observedAt: ISO8601DateFormatter().string(from: dashboardSnapshotFixedNow),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: dashboardSnapshotFixedNow
        ),
        ProviderStatus(
            providerName: "claude",
            providerDisplayName: "Claude",
            ok: true,
            errorMessage: nil,
            windows: [
                ProviderWindow(
                    id: "weekly", percentLeft: 72, resetISO: "2026-08-01T09:58:24-04:00", windowHours: 168,
                    paceDelta: -0.26
                )
            ],
            data: [:],
            observedAt: ISO8601DateFormatter().string(from: dashboardSnapshotFixedNow),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: dashboardSnapshotFixedNow
        )
    ]
}
