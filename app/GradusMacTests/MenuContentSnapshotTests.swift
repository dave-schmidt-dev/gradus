import AppKit
import GradusKit
@testable import GradusMac
import SwiftUI
import Testing

@MainActor
@Test func menuProgressBarPlacesMarkerAtSharedExpectedRemainingPosition() throws {
    let markerFraction = try #require(
        ProgressBar.expectedRemainingMarkerFraction(percentLeft: 62, paceDelta: -0.05)
    )

    #expect(markerFraction == 0.67)
}

@MainActor
@Test func menuProviderRowWithoutPaceKeepsValueAndResetData() {
    let provider = ProviderEntry(
        name: "Codex",
        ok: true,
        error: nil,
        windows: [
            ProviderWindow(
                id: "5h",
                percentLeft: 62,
                resetISO: "2026-08-02T23:00:00Z",
                windowHours: 5,
                paceDelta: nil
            )
        ],
        data: [:],
        observedAt: "2026-08-02T17:55:00Z"
    )

    let markerFraction = ProgressBar.expectedRemainingMarkerFraction(
        percentLeft: provider.windows[0].percentLeft,
        paceDelta: provider.windows[0].paceDelta
    )

    #expect(markerFraction == nil)
    #expect(provider.windows[0].percentLeft == 62)
    #expect(provider.windows[0].resetISO == "2026-08-02T23:00:00Z")
}

private let menuDensityNow = ISO8601DateFormatter().date(from: "2026-08-02T20:00:00-04:00")!

@MainActor
private func menuSnapshotImage(_ view: some View, size: CGSize) -> NSImage {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = 1
    guard let image = renderer.nsImage else {
        fatalError("ImageRenderer failed to produce an NSImage")
    }
    return image
}

private func menuFixture(providerCount: Int, windowsPerProvider: Int) -> [ProviderEntry] {
    (0 ..< providerCount).map { providerIndex in
        ProviderEntry(
            name: "Provider \(providerIndex + 1)",
            ok: true,
            error: nil,
            windows: (0 ..< windowsPerProvider).map { windowIndex in
                ProviderWindow(
                    id: "window-\(windowIndex + 1)",
                    percentLeft: Double(90 - windowIndex * 10),
                    resetISO: "2026-08-03T01:00:00Z",
                    windowHours: 5,
                    paceDelta: -0.05
                )
            },
            data: [:],
            observedAt: "2026-08-02T17:55:00Z"
        )
    }
}

@MainActor
@Test func menuUsesOneReadableDensity() {
    #expect(MenuDensityRung.standard.rowSpacing == MenuContentView.providerRowSpacing)
    #expect(MenuDensityRung.standard.barHeight == MenuContentView.providerBarHeight)
    #expect(MenuDensityRung.standard.providerSpacing == MenuContentView.providerGroupSpacing)
    #expect(MenuVerticalBudget.columnWidth == MenuContentView.columnWidth)
    #expect(MenuDensityRung.standard.metadataFontKind == MenuContentView.providerMetadataFont)
    #expect(MenuDensityRung.standard.barHeight >= 8)
    #expect(MenuContentView.providerBarLeadingInset == 0)
}

/// A compact singleton and expanded provider buckets belong to the same visual
/// grid: labels communicate nesting, never a shifted bar origin.
@MainActor
@Test func menuMixedWindowCountsShareTheBarLeadingEdge() {
    let providers = [
        menuFixture(providerCount: 1, windowsPerProvider: 1)[0],
        menuFixture(providerCount: 2, windowsPerProvider: 2)[1]
    ]
    let image = menuSnapshotImage(
        ProviderListView(providers: providers, now: menuDensityNow),
        size: CGSize(width: MenuContentView.columnWidth, height: 150)
    )
    assertStagedSnapshot(of: image, as: .image)
}

@MainActor
@Test func menuUsesAvailableScreenHeightBeforeScrolling() {
    let visibleScreenHeight: CGFloat = 864
    let referenceHeight = MenuVerticalBudget.referenceHeight(visibleScreenHeight: visibleScreenHeight)
    #expect(referenceHeight == 840)
    #expect(MenuVerticalBudget.referenceHeight(visibleScreenHeight: 500) == MenuVerticalBudget.minimumReferenceHeight)
    #expect(MenuVerticalBudget.referenceHeight(visibleScreenHeight: 1600) == MenuVerticalBudget.maximumReferenceHeight)
    #expect(MenuVerticalBudget.referenceHeight(visibleScreenHeight: nil) == MenuVerticalBudget.fallbackReferenceHeight)
    #expect(MenuVerticalBudget.providerViewportHeight(for: referenceHeight) == 688)

    let resolution = MenuVerticalBudget.resolve(
        providers: menuVisibleFixture(),
        dynamicTypeSize: .medium,
        referenceHeight: referenceHeight
    )

    #expect(resolution.requiredRows == 8)
    #expect(resolution.rung == .standard)
    #expect(resolution.didFit)
    #expect(!resolution.scrolls)
}

@MainActor
@Test func menuProviderListRendersBothFitAndOverflowArms() {
    let fitProviders = menuFixture(providerCount: 2, windowsPerProvider: 1)
    let overflowProviders = menuFixture(providerCount: 8, windowsPerProvider: 4)
    let viewportHeight = MenuVerticalBudget.providerViewportHeight(for: 520)

    let fitImage = menuSnapshotImage(
        MenuProviderListView(providers: fitProviders, now: menuDensityNow, availableMenuHeight: 840)
            .environment(\.dynamicTypeSize, .medium),
        size: CGSize(width: MenuContentView.columnWidth, height: 180)
    )
    let overflowImage = menuSnapshotImage(
        MenuProviderListView(providers: overflowProviders, now: menuDensityNow, availableMenuHeight: 520)
            .environment(\.dynamicTypeSize, .medium),
        size: CGSize(width: MenuContentView.columnWidth, height: viewportHeight)
    )

    #expect(MenuVerticalBudget.resolve(providers: fitProviders, dynamicTypeSize: .medium, referenceHeight: 840).didFit)
    #expect(
        !MenuVerticalBudget.resolve(providers: overflowProviders, dynamicTypeSize: .medium, referenceHeight: 520).didFit
    )
    #expect(fitImage.size.width == MenuContentView.columnWidth)
    #expect(overflowImage.size.height == viewportHeight)
}

@MainActor
@Test func menuOverflowPreservesReadableRows() {
    let providers = menuFixture(providerCount: 8, windowsPerProvider: 4)
    let referenceHeight: CGFloat = 520
    let resolution = MenuVerticalBudget.resolve(
        providers: providers,
        dynamicTypeSize: .medium,
        referenceHeight: referenceHeight
    )

    #expect(resolution.requiredRows == 40)
    #expect(resolution.intrinsicHeight > referenceHeight)
    #expect(resolution.rung == .standard)
    #expect(!resolution.didFit)
    #expect(resolution.scrolls)

    let intrinsicHostingView = NSHostingView(
        rootView: ProviderListView(providers: providers, now: menuDensityNow, density: resolution.rung)
            .environment(\.dynamicTypeSize, .medium)
            .frame(width: MenuContentView.columnWidth, alignment: .leading)
    )
    let intrinsicListHeight = intrinsicHostingView.fittingSize.height
    #expect(intrinsicHostingView.fittingSize.width == MenuContentView.columnWidth)
    #expect(intrinsicListHeight + MenuVerticalBudget.fixedChromeHeight > referenceHeight)

    let viewportHeight = MenuVerticalBudget.providerViewportHeight(for: referenceHeight)
    let overflowHostingView = NSHostingView(
        rootView: MenuProviderListView(
            providers: providers,
            now: menuDensityNow,
            availableMenuHeight: referenceHeight
        )
        .environment(\.dynamicTypeSize, .medium)
        .frame(width: MenuContentView.columnWidth, alignment: .leading)
    )
    #expect(overflowHostingView.fittingSize.height <= viewportHeight)
    #expect(intrinsicListHeight > viewportHeight)

    let image = menuSnapshotImage(
        ProviderListView(providers: providers, now: menuDensityNow, density: resolution.rung),
        size: CGSize(width: MenuContentView.columnWidth, height: intrinsicListHeight)
    )
    assertStagedSnapshot(of: image, as: .image)
}

@Test func menuUsesHumanReadableWindowLabels() {
    #expect(ProviderWindowLabel.label(for: "five_hour") == "5 Hour")
    #expect(ProviderWindowLabel.label(for: "billing_cycle") == "Monthly")
    #expect(ProviderWindowLabel.label(for: "future_window") == "future_window")
}

@Test func menuCompactProviderLabelsDoNotTurnQuotaIDsIntoPlanNames() {
    #expect(MenuContentView.compactProviderLabel(providerName: "Copilot") == "Copilot")
    #expect(MenuContentView.compactProviderLabel(providerName: "Vibe") == "Vibe")
}

@Test func menuWindowMetadataAlwaysExplainsResetAndPace() {
    let dated = ProviderWindow(
        id: "weekly", percentLeft: 60, resetISO: "2026-08-03T01:00:00Z", windowHours: 168, paceDelta: 0
    )
    let unknown = ProviderWindow(
        id: "weekly", percentLeft: 60, resetISO: nil, windowHours: 168, paceDelta: nil
    )
    #expect(MenuWindowMetadata.resetLabel(for: dated, now: menuDensityNow).hasPrefix("resets "))
    #expect(paceLabel(for: dated) == "on pace")
    #expect(MenuWindowMetadata.resetLabel(for: unknown, now: menuDensityNow) == "reset unavailable")
    #expect(paceLabel(for: unknown) == "pace unavailable")
}

private func menuVisibleFixture() -> [ProviderEntry] {
    [1, 1, 1, 1].enumerated().map { index, windowCount in
        ProviderEntry(
            name: "Provider \(index + 1)",
            ok: true,
            error: nil,
            windows: (0 ..< windowCount).map { windowIndex in
                ProviderWindow(
                    id: "window-\(windowIndex + 1)",
                    percentLeft: 80,
                    resetISO: nil,
                    windowHours: 5,
                    paceDelta: nil
                )
            },
            data: [:],
            observedAt: "2026-08-02T17:55:00Z"
        )
    }
}
