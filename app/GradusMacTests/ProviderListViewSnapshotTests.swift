import AppKit
import GradusKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import GradusMac

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
            ]
        )
    )

    let image = snapshotImage(ProviderListView(providers: viewModel.providers), size: CGSize(width: 260, height: 220))
    assertSnapshot(of: image, as: .image)
}

@MainActor
@Test func providerListViewRendersEmptyState() {
    let image = snapshotImage(ProviderListView(providers: []), size: CGSize(width: 260, height: 40))
    assertSnapshot(of: image, as: .image)
}
