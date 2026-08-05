import GradusKit
import SwiftUI

/// The "Now" screen (P3/T3.3): every provider as a `ProviderDensityCard`
/// showing every one of its windows, in `rankProviders`' total order — or one
/// of the three distinct empty states (CV-5) when there's nothing to show yet.
///
/// Both size classes use the same presentation, differing only in column count
/// and whether each window row carries its reset time. The earlier compact
/// layout was a ranked list of `StatTile`s: one hero tile enlarging the worst
/// provider, and one window per provider with the rest behind selection
/// badges. It was replaced rather than kept alongside because the two answered
/// the same question with different amounts of the answer — the phone showed
/// one window per provider while the iPad showed all of them, so the same
/// account read as healthy on one device and not the other.
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
/// Which dashboard presentation to use. Derived from the horizontal size
/// class, but expressible directly so tests can assert the dense layout
/// without depending on how an offscreen snapshot host propagates traits.
enum DashboardLayout {
    /// iPhone and any compact width: the same `ProviderDensityCard`s as iPad in
    /// a single column, with each row's reset column dropped so the bar keeps
    /// enough width to read.
    case denseSingleColumn
    /// iPad and any regular width (Option B): a multi-column grid of
    /// `ProviderDensityCard`s showing every provider *and* every window at
    /// once, no drill-in needed.
    case denseGrid

    /// Both layouts show every window; only the reset column and the column
    /// count differ.
    var showsReset: Bool { self == .denseGrid }
}

struct DashboardContent: View {
    @ObservedObject var viewModel: DashboardViewModel
    let now: Date

    /// `nil` means "follow the size class". Tests pass an explicit value.
    private let layoutOverride: DashboardLayout?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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

    init(viewModel: DashboardViewModel, now: Date = Date(), layout: DashboardLayout? = nil) {
        self.viewModel = viewModel
        self.now = now
        self.layoutOverride = layout
    }

    var layout: DashboardLayout {
        layoutOverride ?? (horizontalSizeClass == .regular ? .denseGrid : .denseSingleColumn)
    }

    var body: some View {
        VStack(spacing: 0) {
            MobileNavBar(title: "Gradus") {
                HStack(spacing: 12) {
                    // Both layouts trade ConnectionInfoCard's four stacked
                    // lines for this one, so the provenance it drops has
                    // somewhere to go. The full computer/user/publish detail
                    // lives in Settings' "Connected Computer" section.
                    SyncStatusLine(
                        source: viewModel.connectedSource,
                        publishedAt: viewModel.connectedSourcePublishedAt,
                        now: now
                    )
                    IconButton(Icon.settings) {
                        showingSettings = true
                    }
                }
            }

            Group {
                if let emptyState = viewModel.emptyState {
                    EmptyStateView(state: emptyState) {
                        viewModel.syncEnabled = true
                    }
                } else {
                    denseGrid
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

    /// One column on iPhone, adaptive on iPad.
    ///
    /// The compact case is `.flexible()` rather than the same
    /// `.adaptive(minimum: 320)`. Adaptive *would* resolve to one column at
    /// 361pt of content width, but only as arithmetic that happens to work
    /// out — a narrower card minimum or a wider phone would silently produce
    /// two cramped columns. Stating "one column" says what is meant.
    private var columns: [GridItem] {
        switch layout {
        case .denseSingleColumn:
            return [GridItem(.flexible(), spacing: 12, alignment: .top)]
        case .denseGrid:
            return [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)]
        }
    }

    /// Every provider and every window at once, on both platforms.
    ///
    /// On iPad, columns are adaptive rather than a fixed two. The mock was
    /// drawn at portrait width, where this resolves to two — but the whole
    /// point is to use the screen, and landscape has room for three. A fixed
    /// count would stretch cards across 1366pt and reintroduce the wasted
    /// horizontal space this layout exists to remove.
    ///
    /// Renders `viewModel.providers` in rank order without splitting exhausted
    /// providers into their own section: at this density an exhausted provider
    /// is legible inline as a card whose rows are all red, and the ranking
    /// already sorts it last. The `showExhausted` preference still applies —
    /// it filters the source array.
    @ViewBuilder
    private var denseGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: columns,
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(viewModel.providers, id: \.providerName) { provider in
                    ProviderDensityCard(provider: provider, now: now, showsReset: layout.showsReset)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedProviderName = provider.providerName
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

}
