import GradusKit
import SwiftUI

/// The "Now" screen (P3/T3.3): a hero `StatTile` for the single most urgent
/// provider (`viewModel.heroProvider`, per `rankProviders`' total order)
/// followed by compact `StatTile` rows for the rest, or one of the three
/// distinct empty states (CV-5) when there's nothing to show yet.
///
/// Root is a populated `NavigationStack`: the dashboard is always the first
/// screen, including on compact iPhone widths. Provider detail remains a
/// normal push destination, so its back affordance returns to this populated
/// root rather than an empty split-view sidebar.
struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let now: Date

    init(viewModel: DashboardViewModel, now: Date = Date()) {
        self.viewModel = viewModel
        self.now = now
    }

    var body: some View {
        NavigationStack {
            DashboardContent(viewModel: viewModel, now: now)
        }
    }
}

/// The "Now" screen's actual content, factored out of `DashboardView.body`
/// (T3.3 gate) so it's directly snapshot-testable and independently
/// reusable. Factored out specifically to sidestep a distinct
/// navigation shell. `DashboardSnapshotTests` snapshots this type directly so
/// content ordering stays independently testable from navigation chrome.
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

            if let source = viewModel.connectedSource {
                ConnectionInfoCard(
                    source: source,
                    publishedAt: viewModel.connectedSourcePublishedAt,
                    now: now
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
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
            if let hero = activeProviders.first {
                StatTile(
                    provider: hero,
                    selectedWindow: selectedWindow(for: hero),
                    badgeWindows: badgeWindows(for: hero),
                    isHero: true,
                    now: now,
                    onSelectWindow: { window in
                        viewModel.selectWindow(providerName: hero.providerName, windowID: window.id)
                    }
                )
                .listRowSeparator(.hidden)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedProviderName = hero.providerName
                }
            }

            ForEach(activeProviders.dropFirst(), id: \.providerName) { provider in
                StatTile(
                    provider: provider,
                    selectedWindow: selectedWindow(for: provider),
                    badgeWindows: badgeWindows(for: provider),
                    now: now,
                    onSelectWindow: { window in
                        viewModel.selectWindow(providerName: provider.providerName, windowID: window.id)
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedProviderName = provider.providerName
                }
            }

            if !exhaustedProviders.isEmpty {
                Section("Exhausted") {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 8
                    ) {
                        ForEach(exhaustedProviders, id: \.providerName) { provider in
                            exhaustedCell(for: provider)
                            .accessibilityIdentifier("exhausted-provider-\(provider.providerName)")
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedProviderName = provider.providerName
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSpacing(0)
    }

    /// `rankProviders` guarantees active providers precede exhausted ones;
    /// keep the presentation split explicit so the hero can never be an
    /// exhausted provider, regardless of the selected local sort mode.
    private var activeProviders: [ProviderStatus] {
        viewModel.providers.filter { !$0.isDepleted }
    }

    /// `DashboardViewModel.showExhausted` filters this source array. When it
    /// is off, this is empty and no compact exhausted cells are rendered.
    private var exhaustedProviders: [ProviderStatus] {
        viewModel.providers.filter(\.isDepleted)
    }

    private func exhaustedCell(for provider: ProviderStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(provider.providerDisplayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text("Exhausted")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func selectedWindow(for provider: ProviderStatus) -> ProviderWindow? {
        viewModel.selectedWindow(for: provider)
    }

    /// All valid non-selected windows become compact selection badges. The
    /// provider name and id are passed unchanged to the view-model API.
    private func badgeWindows(for provider: ProviderStatus) -> [ProviderWindow] {
        guard let selected = selectedWindow(for: provider) else { return [] }
        return provider.windows.filter {
            percentIsValid($0.percentLeft) && $0.id != selected.id
        }
    }
}
