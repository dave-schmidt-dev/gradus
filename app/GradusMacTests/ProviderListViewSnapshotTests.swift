import AppKit
import GradusKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import GradusMac

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
private func snapshotImage<V: View>(_ view: V, size: CGSize) -> NSImage {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = 1
    guard let image = renderer.nsImage else {
        fatalError("ImageRenderer failed to produce an NSImage")
    }
    return image
}

// T2b.1/T2b.4 gate: XCUITest can't drive a LSUIElement status item, so the
// provider rows are rendered standalone (fixture data, no CloudKit/file
// watching) and snapshot-tested instead.
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
                ),
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

/// Pixel coverage for the 2026-08-06 attention rule, which nothing else has.
///
/// `ProviderTriage.needsAttention` gates the metadata line under each bar
/// (`MenuContentView.swift:317`), so the rule has a visible consequence — but
/// every provider in `providerListViewRendersFromFixtureData` carries exactly
/// one window, and with one window "any window" and "the worst window" are the
/// same question. The whole rule change could have been reverted with that
/// baseline still green. This is the fixture that inverts: `Codex`'s
/// worst-by-percentage window is fine and its *other* window is not, so the old
/// worst-window rule renders no metadata line here and the new one does.
///
/// `Claude` is the control. It is the same shape with both windows healthy, so
/// a rule that simply flagged everything would not pass either.
@MainActor
@Test func providerListViewFlagsAProviderWhoseWorstWindowIsNotItsProblem() {
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
                        // Lowest percentage, and entirely healthy: nearly
                        // through its window with a little left.
                        ProviderWindow(
                            id: "5h",
                            percentLeft: 5,
                            resetISO: "2026-08-02T20:12:00Z",
                            windowHours: 5,
                            paceDelta: 0.02
                        ),
                        // The actual problem, and never the worst by
                        // percentage. Reachable: 2% of the week elapsed, 30%
                        // of the budget already gone.
                        ProviderWindow(
                            id: "weekly",
                            percentLeft: 70,
                            resetISO: "2026-08-09T12:00:00Z",
                            windowHours: 168,
                            paceDelta: -0.28
                        ),
                    ],
                    data: [:],
                    observedAt: "2026-08-02T17:55:00Z"
                ),
                ProviderEntry(
                    name: "Claude",
                    ok: true,
                    error: nil,
                    windows: [
                        ProviderWindow(
                            id: "5h",
                            percentLeft: 8,
                            resetISO: "2026-08-02T20:15:00Z",
                            windowHours: 5,
                            paceDelta: 0.03
                        ),
                        ProviderWindow(
                            id: "weekly",
                            percentLeft: 74,
                            resetISO: "2026-08-09T12:00:00Z",
                            windowHours: 168,
                            paceDelta: 0.06
                        ),
                    ],
                    data: [:],
                    observedAt: "2026-08-02T17:55:00Z"
                ),
            ]
        )
    )

    let providers = viewModel.providers
    let codex = providers.first { $0.name == "Codex" }!
    let claude = providers.first { $0.name == "Claude" }!
    // Assert the discrimination directly as well as in pixels: a snapshot
    // records whatever it is given, so if the fixture stopped being the
    // inverting case the baseline would simply be re-recorded and look fine.
    #expect(ProviderTriage.worstWindow(codex)?.id == "5h")
    #expect(ProviderTriage.needsAttention(codex))
    #expect(!ProviderTriage.needsAttention(claude))

    let image = snapshotImage(
        ProviderListView(providers: providers, now: fixedNow),
        size: CGSize(width: 256, height: 150)
    )
    assertSnapshot(of: image, as: .image)
}

@MainActor
@Test func providerListViewRendersEmptyState() {
    let image = snapshotImage(ProviderListView(providers: []), size: CGSize(width: 256, height: 40))
    assertSnapshot(of: image, as: .image)
}
