import GradusKit
import SwiftUI

/// The "Now" screen (P3/T3.3): a hero `StatTile` for the single most urgent
/// provider (`viewModel.heroProvider`, per `rankProviders`' total order)
/// followed by compact `StatTile` rows for the rest, or one of the three
/// distinct empty states (CV-5) when there's nothing to show yet.
///
/// Root is `NavigationSplitView`, per Key decision #3
/// (`ios-design-system-2026-08-03.md`) -- preserving the future iPad
/// dense-layout seam (an eventual populated sidebar column).
///
/// `preferredCompactColumn` is required: it's the parameter that controls
/// which column a `NavigationSplitView` shows once it collapses to one
/// column on a compact-width device (iPhone). Without it, a collapsed split
/// view defaults to showing the *sidebar* -- which is empty here -- so the
/// app renders a blank screen. This was originally misdiagnosed (during
/// T3.3/T3.5 verification) as `NavigationSplitView` itself being broken on
/// real devices, because every configuration tried at the time only varied
/// `columnVisibility`, which governs *regular-width* (iPad) column layout
/// and has no effect on compact collapse -- so every "configuration" was
/// the same experiment repeated. Confirmed via `xcrun simctl io screenshot`
/// on a manually-launched build: `NavigationSplitView(preferredCompactColumn:
/// $preferredColumn)` with `preferredColumn = .detail` renders correctly on
/// the first frame.
///
/// `preferredCompactColumn` requires iOS 17+, which is why `GradusiOS`'s
/// deployment target was bumped from 16.0 to 17.0 (`project.yml`) alongside
/// this change -- David's call, since dropping iOS 16 device support is a
/// product decision, not an engineering default.
struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let now: Date
    @State private var preferredColumn = NavigationSplitViewColumn.detail

    init(viewModel: DashboardViewModel, now: Date = Date()) {
        self.viewModel = viewModel
        self.now = now
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            EmptyView()
        } detail: {
            DashboardContent(viewModel: viewModel, now: now)
        }
    }
}

/// The "Now" screen's actual content, factored out of `DashboardView.body`
/// (T3.3 gate) so it's directly snapshot-testable and independently
/// reusable. Factored out specifically to sidestep a distinct
/// `NavigationSplitView` incompatibility: snapshotting `DashboardView`
/// directly through swift-snapshot-testing's offscreen, synthetic
/// `UIHostingController` (no real `UIWindow`/scene) let
/// `NavigationSplitView`'s internal collapse-column negotiation produce a
/// degenerate rendered image, which crashed swift-snapshot-testing's
/// image-diffing code (`SIGSEGV`, seen in a `dashboardRendersPopulatedCards*`
/// run this session) rather than failing gracefully. `DashboardSnapshotTests`
/// snapshots this type instead of `DashboardView`, sidestepping the
/// `NavigationSplitView` wrapper entirely -- unrelated to the separate
/// on-device `preferredCompactColumn` issue documented on `DashboardView`
/// above; that one's about real launches, this one's about the offscreen
/// snapshot-testing harness.
struct DashboardContent: View {
    @ObservedObject var viewModel: DashboardViewModel
    let now: Date
    /// Row-tap navigation target (P4/T4.2): set on tap of either the hero
    /// `StatTile` or a compact ranked-row `StatTile`, pushing
    /// `ProviderDetailView` for that provider. Tracked by `providerName`
    /// (not the `ProviderStatus` value itself) since `ProviderStatus` isn't
    /// `Hashable` and `.navigationDestination(item:)` requires that --
    /// looking the provider back up from `viewModel.providers` by name
    /// keeps this file from having to add a `Hashable` conformance to a
    /// `GradusKit` model type for a purely-iOS navigation concern.
    @State private var selectedProviderName: String?
    /// Settings presentation (P5/T5.3): a sheet rather than a
    /// `navigationDestination` push -- decoupled from the `selectedProviderName`
    /// push-navigation state Phase 4 owns above, and matches the design
    /// system's "one trailing accessory" nav-bar rule without needing
    /// Settings to participate in the same navigation stack as provider
    /// detail drill-in.
    @State private var showingSettings = false

    init(viewModel: DashboardViewModel, now: Date = Date()) {
        self.viewModel = viewModel
        self.now = now
    }

    var body: some View {
        VStack(spacing: 0) {
            MobileNavBar(title: "Gradus") {
                IconButton(Icon.settings) {
                    showingSettings = true
                }
            }

            Group {
                if let emptyState = viewModel.emptyState {
                    EmptyStateView(state: emptyState) {
                        viewModel.syncEnabled = true
                    }
                } else {
                    nowList
                }
            }
        }
        .navigationDestination(item: $selectedProviderName) { providerName in
            if let provider = viewModel.providers.first(where: { $0.providerName == providerName }) {
                ProviderDetailView(provider: provider, now: now)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(dashboardViewModel: viewModel)
        }
    }

    @ViewBuilder
    private var nowList: some View {
        List {
            if let hero = viewModel.heroProvider {
                StatTile(
                    provider: hero, worstWindow: worstWindow(for: hero), isHero: true,
                    isLocallyUrgent: isLocallyUrgent(for: hero)
                )
                .listRowSeparator(.hidden)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedProviderName = hero.providerName
                }
            }
            ForEach(viewModel.restProviders, id: \.providerName) { provider in
                StatTile(
                    provider: provider, worstWindow: worstWindow(for: provider), isHero: false,
                    isLocallyUrgent: isLocallyUrgent(for: provider)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedProviderName = provider.providerName
                }
            }
        }
        .listStyle(.plain)
    }

    /// Mirrors `ProviderCard.swift`'s existing `worstWindow` computation
    /// (lowest `percentLeft`), the same definition `rankProviders` uses.
    private func worstWindow(for provider: ProviderStatus) -> ProviderWindow? {
        provider.windows.min { $0.percentLeft < $1.percentLeft }
    }

    /// P5/T5.2: whether this provider's `StatTile` gets the local-urgent
    /// ring, evaluated against the live `localWarningThresholdPercent`
    /// (not a hardcoded default) -- `false` when there's no window to
    /// evaluate (errored/no-data providers), matching `localIsUrgent`'s own
    /// guard on `worstWindow == nil`.
    private func isLocallyUrgent(for provider: ProviderStatus) -> Bool {
        guard let worst = worstWindow(for: provider) else { return false }
        return localIsUrgent(worst, threshold: viewModel.localWarningThresholdPercent)
    }
}
