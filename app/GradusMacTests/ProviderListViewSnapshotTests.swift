import AppKit
import GradusKit
@testable import GradusMac
import SnapshotTesting
import SwiftUI
import Testing

private let fixedNow = ISO8601DateFormatter().date(from: "2026-08-02T20:00:00-04:00")!

/// `Snapshotting<SwiftUI.View, NSImage>` isn't provided by
/// swift-snapshot-testing 1.19.4 on macOS (only iOS/tvOS get that
/// convenience) -- host the view in an `NSHostingView` and use the
/// `NSView` strategy instead.
/// `NSHostingView` + `cacheDisplay(in:to:)` (the NSView snapshot strategy's
/// capture path) doesn't reliably rasterize SwiftUI's Text/control layers
/// offscreen -- rows came back with progress bars but no text at all.
/// `ImageRenderer` (macOS 13+, matching this app's deployment target) is
/// SwiftUI's own rasterizer and renders correctly without a live window --
/// EXCEPT for AppKit-representable-backed controls (`Toggle`, the native
/// `ProgressView`), which come back as a placeholder glyph even under
/// `ImageRenderer`. That's why these tests snapshot `ProviderListView`
/// (Text + plain shapes only) rather than the full `MenuContentView`: the
/// `Toggle`/`Button` controls are covered by the plan's manual
/// status-item check instead, not this automated gate.
@MainActor
private func snapshotImage(_ view: some View, size: CGSize) -> NSImage {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = 1
    guard let image = renderer.nsImage else {
        fatalError("ImageRenderer failed to produce an NSImage")
    }
    return image
}

/// T2b.1/T2b.4 gate: XCUITest can't drive a LSUIElement status item, so the
/// provider rows are rendered standalone (fixture data, no CloudKit/file
/// watching) and snapshot-tested instead.
@MainActor
@Test func providerListViewRendersFromFixtureData() {
    let viewModel = PublisherViewModel()
    viewModel.apply(
        SnapshotPayload(
            schemaVersion: 2,
            updatedAt: "2026-08-02T18:00:00Z",
            providers: [
                ProviderEntry(
                    name: "Codex",
                    ok: true,
                    error: nil,
                    windows: [
                        ProviderWindow(
                            id: "5h",
                            percentLeft: 62,
                            resetISO: "2026-08-02T23:00:00Z",
                            windowHours: 5,
                            paceDelta: -0.05
                        )
                    ],
                    data: [:],
                    observedAt: "2026-08-02T17:55:00Z"
                ),
                ProviderEntry(
                    name: "Antigravity (Claude)",
                    ok: true,
                    error: nil,
                    windows: [
                        ProviderWindow(
                            id: "weekly",
                            percentLeft: 4,
                            resetISO: "2026-08-05T00:00:00Z",
                            windowHours: 168,
                            paceDelta: -0.30
                        )
                    ],
                    data: [:],
                    observedAt: "2026-08-02T17:55:00Z"
                ),
                ProviderEntry(
                    name: "Cursor",
                    ok: false,
                    error: "transient fetch failure",
                    windows: [],
                    data: [:],
                    observedAt: nil
                ),
                // Depleted, and deliberately listed first-ish in the input so
                // the baseline proves the *sort* moved it, not the fixture
                // order. Its presence is the point: with no depleted provider
                // in this fixture the exhausted section never renders, and the
                // whole compact treatment could be deleted with a green gate --
                // exactly how the equivalent iOS cell was lost (TASKS row 21).
                ProviderEntry(
                    name: "Copilot",
                    ok: true,
                    error: nil,
                    windows: [
                        ProviderWindow(
                            id: "weekly",
                            percentLeft: 0,
                            resetISO: "2026-08-04T04:00:00Z",
                            windowHours: 168,
                            paceDelta: -0.60
                        )
                    ],
                    data: [:],
                    observedAt: "2026-08-02T17:55:00Z"
                )
            ]
        )
    )

    // 256 = MenuContentView's 280pt frame minus its 12pt padding on each
    // side, so the baseline is rendered at the width the row actually gets in
    // the live menu rather than an arbitrary one.
    let image = snapshotImage(
        ProviderListView(providers: viewModel.providers, now: fixedNow),
        size: CGSize(width: 256, height: 260)
    )
    assertSnapshot(of: image, as: .image)
}

/// A failed refresh still carries the last known-good windows. The menu must
/// keep the value visible without turning the provider back into a healthy row,
/// and must show the provider-authored remedy alongside it.
@MainActor
@Test func providerListViewShowsRetainedValuesAndActionableFailure() {
    let provider = ProviderEntry(
        name: "Cursor",
        ok: false,
        error: "Claude session expired: sign in at claude.ai",
        windows: [
            ProviderWindow(
                id: "five_hour",
                percentLeft: 62,
                resetISO: "2026-08-03T01:00:00-04:00",
                windowHours: 5,
                paceDelta: -0.05
            )
        ],
        data: [:],
        observedAt: "2026-08-02T19:50:00-04:00"
    )

    #expect(!provider.ok)
    #expect(provider.windows.first?.percentLeft == 62)
    #expect(percentDisplay(provider.windows.first?.percentLeft) == "62%")
    #expect(provider.error == "Claude session expired: sign in at claude.ai")

    // Render the exact row path without adding a Mac PNG baseline. The direct
    // assertions above keep this test about the two user-visible contracts,
    // while rendering catches a type/layout regression in the retained path.
    let image = snapshotImage(
        ProviderListView(providers: [provider], now: fixedNow),
        size: CGSize(width: 256, height: 100)
    )
    #expect(image.size == CGSize(width: 256, height: 100))
}

/// The ramp itself, one provider per step, which nothing else covered.
///
/// `providerListViewRendersFromFixtureData` was the only Mac image snapshot
/// with a colored bar in it, and its four providers land on yellow, red, red
/// and a probe error — so green and orange had no pixel coverage at all. When
/// the Mac adopted the four-tier ramp on 2026-08-05, exactly one baseline
/// moved. Half the ramp could have been given the wrong hex and the gate would
/// have stayed green.
///
/// Every provider here carries exactly one window, deliberately. This baseline
/// moves only when a *color* changes; the 8×4 menu fixture owns the all-window
/// rendering contract. Keeping the two properties in separate fixtures is what
/// lets a diff here mean one thing.
///
/// `Slow Burn` reaches red without a pace, through the percent-only 70/40/20
/// fallback a window without a reset timestamp still uses. Since 2026-08-06
/// that path also warns, so it is the one row whose metadata line shows a
/// reset with no pace label beside it.
@MainActor
@Test func providerListViewRendersEveryRampLevel() {
    let viewModel = PublisherViewModel()
    viewModel.apply(
        SnapshotPayload(
            schemaVersion: 2,
            updatedAt: "2026-08-02T18:00:00Z",
            providers: [
                // green: ahead of the clock. 85% left, 75% of the window to run.
                rampProvider("Healthy", percentLeft: 85, paceDelta: 0.10),
                // yellow: drifting, below the alert bound.
                rampProvider("Drifting", percentLeft: 55, paceDelta: -0.06),
                // orange: first step that warns, so metadata appears from here down.
                rampProvider("Behind", percentLeft: 35, paceDelta: -0.18),
                // red: past the -0.25 floor.
                rampProvider("Burning", percentLeft: 20, paceDelta: -0.35),
                // red with no pace at all -- percent-only fallback, 19 < 20.
                rampProvider("Slow Burn", percentLeft: 19, paceDelta: nil)
            ]
        )
    )

    let providers = viewModel.providers
    // Assert the levels rather than trusting the fixture to still land on them:
    // a baseline records whatever it is handed, so if a pace bound moved, these
    // five could collapse onto three steps and the re-recorded image would look
    // perfectly plausible.
    let levelsByName = Dictionary(
        uniqueKeysWithValues: providers.compactMap { entry -> (String, SignalLevel)? in
            guard let window = entry.windows.first else { return nil }
            return (entry.name, signalLevel(for: window))
        }
    )
    #expect(levelsByName["Healthy"] == .green)
    #expect(levelsByName["Drifting"] == .yellow)
    #expect(levelsByName["Behind"] == .orange)
    #expect(levelsByName["Burning"] == .red)
    #expect(levelsByName["Slow Burn"] == .red)
    #expect(Set(levelsByName.values) == Set([.green, .yellow, .orange, .red]))

    let image = snapshotImage(
        ProviderListView(providers: providers, now: fixedNow),
        size: CGSize(width: 256, height: 300)
    )
    // ImageRenderer's text antialiasing changes by a few subpixels across
    // Xcode runtimes; the fixture's exact level assertions above retain the
    // semantic color gate while this permits that renderer-only variation.
    assertSnapshot(of: image, as: .image(precision: 0.999))
}

/// Single-window provider for the ramp baseline. `resetISO` is always present
/// so the warning rows render a complete metadata line and the image is about
/// color rather than about which labels happen to be missing.
private func rampProvider(
    _ name: String, percentLeft: Double, paceDelta: Double?
) -> ProviderEntry {
    ProviderEntry(
        name: name,
        ok: true,
        error: nil,
        windows: [
            ProviderWindow(
                id: "5h",
                percentLeft: percentLeft,
                resetISO: "2026-08-02T23:30:00Z",
                windowHours: 5,
                paceDelta: paceDelta
            )
        ],
        data: [:],
        observedAt: "2026-08-02T17:55:00Z"
    )
}

@MainActor
@Test func providerListViewRendersEmptyState() {
    let image = snapshotImage(ProviderListView(providers: []), size: CGSize(width: 256, height: 40))
    assertSnapshot(of: image, as: .image)
}
