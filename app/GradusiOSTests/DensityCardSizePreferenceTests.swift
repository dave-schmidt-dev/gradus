@testable import GradusiOS
import GradusKit
import SwiftUI
import Testing
import UIKit

// Card-size preference persistence and settings-binding coverage split
// out of `DensityLayoutTests`.

private let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)

/// Device-local, like the sort option and exhausted-visibility controls it sits
/// beside in Settings' "Local Display" section. `0` is Auto; positive values
/// are the slider's Small-to-Large stops, which the dashboard clamps against
/// the actual device geometry and Dynamic Type size.
@MainActor
@Test func densityPersistsPerDeviceAndDefaultsToCompact() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-density-pref-\(UUID().uuidString)", isDirectory: true)
    let suite = scratchSuiteName("density-pref")
    let defaults = try #require(scratchDefaults(named: suite))
    defer { removeScratchDefaultsSuite(suite) }

    // Unset defaults to Auto. The selected count is resolved only from the
    // live container and Dynamic Type environment, not provider data.
    let viewModel = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults
    )
    #expect(viewModel.cardColumnPreference == 0)

    viewModel.cardColumnPreference = 3
    #expect(defaults.integer(forKey: DashboardViewModel.cardColumnPreferenceKey) == 3)

    // Survives a relaunch against the same defaults.
    let relaunched = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults
    )
    #expect(relaunched.cardColumnPreference == 3)

    // A stale invalid value falls back to Auto rather than producing an
    // impossible slider position.
    defaults.set(-1, forKey: DashboardViewModel.cardColumnPreferenceKey)
    let unknown = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults
    )
    #expect(unknown.cardColumnPreference == 0)
}

@MainActor
@Test func legacyColumnPreferenceMigratesAfterGeometryIsKnown() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-density-migration-\(UUID().uuidString)", isDirectory: true)
    let defaults = try #require(scratchDefaults("density-migration"))

    // Build 12 stored a direct column count. Before geometry is available the
    // new model stays on Auto rather than briefly treating that number as a
    // size stop; the first dashboard geometry pass translates it exactly.
    defaults.set(3, forKey: DashboardViewModel.cardColumnPreferenceKey)
    let viewModel = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults
    )
    #expect(viewModel.cardColumnPreference == 0)

    viewModel.setAvailableCardColumns(5)
    #expect(viewModel.cardColumnPreference == 3, "three old columns should remain three columns")
    #expect(defaults.integer(forKey: DashboardViewModel.cardColumnPreferenceKey) == 3)

    let relaunched = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults
    )
    #expect(relaunched.cardColumnPreference == 3)
}

@MainActor
@Test func legacyColumnPreferenceDoesNotRemigrateAfterOneColumnGeometry() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-density-migration-one-column-\(UUID().uuidString)", isDirectory: true)
    let defaults = try #require(scratchDefaults("density-migration-one-column"))
    defaults.set(3, forKey: DashboardViewModel.cardColumnPreferenceKey)

    let viewModel = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults
    )
    viewModel.setAvailableCardColumns(1)
    #expect(viewModel.cardColumnPreference == 0)
    #expect(defaults.integer(forKey: DashboardViewModel.cardColumnPreferenceKey) == 0)

    let relaunched = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults
    )
    relaunched.setAvailableCardColumns(4)
    #expect(relaunched.cardColumnPreference == 2, "three legacy columns should map to two stops from Small")
}

@Test func cardSizeStopsKeepAutoExplicitAndInvertLargeToSmall() {
    // Auto stays a distinct persisted value. Explicit positions run from
    // the smallest cards on the left to one large card on the right. A
    // one-column device has no manual positions because none can change its
    // layout.
    #expect(DashboardViewModel.cardSizeStopCount(for: 1) == 1)
    #expect(DashboardViewModel.resolvedCardDensity(preference: 0, sizeStops: 1) == nil)
    #expect(
        DashboardViewModel.resolvedCardColumnCount(
            preference: 0, maximum: 1, sizeStops: 1
        ) == 1
    )

    #expect(
        DashboardViewModel.resolvedCardColumnCount(
            preference: 1, maximum: 4, sizeStops: 4
        ) == 4
    )
    #expect(
        DashboardViewModel.resolvedCardColumnCount(
            preference: 4, maximum: 4, sizeStops: 4
        ) == 1
    )
    #expect(
        DashboardViewModel.cardSizeLabel(preference: 0, maximumColumns: 1) == "Auto"
    )
    #expect(
        DashboardViewModel.cardSizeLabel(preference: 1, maximumColumns: 4)
            .hasPrefix("Small · 4 columns")
    )
    #expect(
        DashboardViewModel.cardSizeLabel(preference: 3, maximumColumns: 1)
            == "Auto"
    )
}

@MainActor
@Test func oneColumnGeometryForcesAutomaticCardSize() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-one-column-size-\(UUID().uuidString)", isDirectory: true)
    let defaults = try #require(scratchDefaults("one-column-size"))
    let viewModel = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults
    )

    viewModel.setAvailableCardColumns(4)
    viewModel.cardColumnPreference = 4
    viewModel.setAvailableCardColumns(1)

    #expect(viewModel.cardColumnPreference == 0)
    #expect(defaults.integer(forKey: DashboardViewModel.cardColumnPreferenceKey) == 0)
    #expect(DashboardViewModel.cardSizeStopCount(for: viewModel.availableCardColumns) == 1)

    viewModel.setAvailableCardColumns(4)
    #expect(viewModel.cardColumnPreference == 4, "the iPad should restore its deferred Large stop")
}

@MainActor
@Test func automaticCardSizeDisablesManualSlider() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-card-size-binding-\(UUID().uuidString)", isDirectory: true)
    let suite = scratchSuiteName("card-size-binding")
    let viewModel = try DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory),
        userDefaults: #require(scratchDefaults(named: suite))
    )
    viewModel.setAvailableCardColumns(4)
    let settings = SettingsView(dashboardViewModel: viewModel)

    #expect(settings.cardSizeSliderEnabled == false)
    settings.automaticCardSizeBinding.wrappedValue = false
    #expect(viewModel.cardColumnPreference == 1)
    #expect(settings.cardSizeSliderEnabled)

    settings.automaticCardSizeBinding.wrappedValue = true
    #expect(viewModel.cardColumnPreference == 0)
    #expect(settings.cardSizeSliderEnabled == false)

    viewModel.setAvailableCardColumns(1)
    #expect(viewModel.cardColumnPreference == 0)
    #expect(settings.cardSizeSliderEnabled == false)
}

@MainActor
@Test func cardSizeAccessibilityMovesOneWholeStopAtATime() {
    let slider = QuietDiscreteUISlider()
    slider.minimumValue = 1
    slider.maximumValue = 3
    slider.value = 1

    slider.accessibilityIncrement()
    #expect(slider.value == 2)
    slider.accessibilityIncrement()
    #expect(slider.value == 3)
    slider.accessibilityIncrement()
    #expect(slider.value == 3)

    slider.accessibilityDecrement()
    #expect(slider.value == 2)
    slider.accessibilityDecrement()
    #expect(slider.value == 1)
    slider.accessibilityDecrement()
    #expect(slider.value == 1)

    slider.isEnabled = false
    slider.accessibilityIncrement()
    slider.accessibilityDecrement()
    #expect(slider.value == 1)
}

/// Asking for compact explicitly remains a stable snapshot fixture while the
/// production path resolves its rung from slider-selected card width.
///
/// This is the property a duplicate `.compact` snapshot baseline appeared to
/// cover and did not: two baselines rendered from the same metrics move
/// together under any edit, so neither can catch the other drifting. What can
/// actually break here is the *override plumbing* — a `densityOverride` that
/// was ignored, or a default that stopped being compact — and that is a
/// comparison of resolved values, not of pixels.
@MainActor
@Test func explicitCompactResolvesTheSameAsTheDefault() {
    let viewModel = makeDensityViewModel(providers: [provider("codex", windows: [window("weekly", 50)])])
    #expect(viewModel.cardColumnPreference == 0)

    let explicit = DashboardContent(
        viewModel: viewModel, now: fixedNow, layout: .denseGrid, density: .compact
    )
    let byPreference = DashboardContent(viewModel: viewModel, now: fixedNow, layout: .denseGrid)
    #expect(explicit.metrics == byPreference.metrics)

    // The override must actually override, or the two fixtures above would
    // agree for the wrong reason.
    let overridden = DashboardContent(
        viewModel: viewModel, now: fixedNow, layout: .denseGrid, density: .large
    )
    #expect(overridden.metrics != byPreference.metrics)

    let standard = DashboardDensity.resolveRung { $0 == .standard }
    #expect(standard.rung == .standard && standard.didFit)
    let fallback = DashboardDensity.resolveRung { _ in false }
    #expect(fallback.rung == .compact && !fallback.didFit)
}

/// The two axes must stay independent: density is the user's choice, the reset
/// column is a width consequence. Crossing them is how "large on iPhone"
/// would end up with a reset column it has no room for.
@MainActor
@Test func densityDoesNotDecideTheResetColumn() {
    let viewModel = makeDensityViewModel(providers: [provider("codex", windows: [window("weekly", 50)])])
    for density in DashboardDensity.allCases {
        let metrics = density.metrics
        let gridColumns = maxColumns(
            containerWidth: 802,
            scaledFixedColumnWidth: 0,
            cardPadding: 0,
            cardGap: metrics.cardGap,
            minimumBarWidth: metrics.gridMinimum
        )
        #expect(
            !DashboardContent(
                viewModel: viewModel, now: fixedNow, layout: .denseSingleColumn, density: density
            ).runtimeShowsReset(
                inContentWidth: 361,
                columns: 1,
                scaledFixedColumnWidth: metrics.fixedColumnWidth(showsReset: true)
            )
        )
        #expect(
            DashboardContent(
                viewModel: viewModel, now: fixedNow, layout: .denseGrid, density: density
            ).runtimeShowsReset(
                inContentWidth: 802,
                columns: gridColumns,
                scaledFixedColumnWidth: metrics.fixedColumnWidth(showsReset: true)
            )
        )
    }
}
