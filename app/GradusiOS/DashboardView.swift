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
    /// `nil` means "use the stored preference". Snapshot tests pass an explicit
    /// density so a baseline names the density it depicts rather than depending
    /// on whatever `UserDefaults` the fixture happened to build.
    private let densityOverride: DashboardDensity?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Row-tap navigation target (P4/T4.2): set on tap of any
    /// `ProviderDensityCard`, pushing `ProviderDetailView` for that provider.
    /// Same behavior in both layouts (INV-12). Tracked by `providerName`
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

    init(
        viewModel: DashboardViewModel,
        now: Date = Date(),
        layout: DashboardLayout? = nil,
        density: DashboardDensity? = nil
    ) {
        self.viewModel = viewModel
        self.now = now
        self.layoutOverride = layout
        self.densityOverride = density
    }

    var layout: DashboardLayout {
        layoutOverride ?? (horizontalSizeClass == .regular ? .denseGrid : .denseSingleColumn)
    }

    var body: some View {
        VStack(spacing: 0) {
            MobileNavBar(title: "Gradus") {
                HStack(spacing: 12) {
                    // Both layouts traded the former ConnectionInfoCard's four
                    // stacked lines for this one, so the provenance it dropped
                    // has somewhere to go. The full computer/user/publish
                    // detail lives in Settings' "Connected Computer" section.
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
    /// The user's density, or the test override. Read once here and threaded
    /// down; no descendant re-derives it.
    var metrics: DensityMetrics {
        (densityOverride ?? viewModel.density).metrics
    }

    private var columns: [GridItem] {
        switch layout {
        case .denseSingleColumn:
            return [GridItem(.flexible(), spacing: metrics.cardGap, alignment: .top)]
        case .denseGrid:
            // The minimum is a density metric because density scales the row's
            // fixed columns, not just its height — at `.large` a 320pt card
            // could not seat them and a readable bar at the same time. One
            // column on an 11" iPad in portrait at `.large` is the intended
            // result, not an accident of the number.
            return [
                GridItem(
                    .adaptive(minimum: metrics.gridMinimum),
                    spacing: metrics.cardGap,
                    alignment: .top)
            ]
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
    /// Active providers as full density cards, then exhausted ones in a
    /// compact section at the bottom.
    ///
    /// An earlier version rendered exhausted providers inline as ordinary
    /// cards, on the reasoning that the ranking already sorts them last and an
    /// all-red card reads as spent. In practice that spends a full card —
    /// every window, every bar — on the one provider you can do nothing about,
    /// and on a phone it pushes the actionable rows off the first screen. A
    /// spent provider raises exactly one question: when does it come back.
    /// Name and reset time answer it in two lines.
    ///
    /// The `showExhausted` preference still applies upstream — it filters the
    /// source array, so hiding them removes this section entirely.
    @ViewBuilder
    private var denseGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(
                    columns: columns,
                    alignment: .leading,
                    spacing: metrics.cardGap
                ) {
                    ForEach(activeProviders, id: \.providerName) { provider in
                        ProviderDensityCard(
                            provider: provider,
                            now: now,
                            showsReset: layout.showsReset,
                            metrics: metrics
                        )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedProviderName = provider.providerName
                            }
                    }
                }
                if !exhaustedProviders.isEmpty {
                    exhaustedSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    /// `viewModel.providers` already arrives in `rankedPartition` order with
    /// exhausted last, so filtering here preserves both the split and the
    /// order within each half — it does not re-derive either.
    private var activeProviders: [ProviderStatus] {
        viewModel.providers.filter { !$0.isDepleted }
    }

    private var exhaustedProviders: [ProviderStatus] {
        viewModel.providers.filter(\.isDepleted)
    }

    /// Two per row on iPhone, wider on iPad.
    ///
    /// Sized from the content, not from the card grid: a cell holds a provider
    /// name and "resets Aug 12, 7:46 PM". A 150pt minimum packs four columns
    /// onto an iPad and truncates both strings — which defeats the point,
    /// since the reset time is the entire reason the cell exists. The compact
    /// numbers (170/240) keep them whole at every width this app is used at,
    /// and the larger densities scale from there with their reset font.
    private var exhaustedColumns: [GridItem] {
        let minimum =
            switch layout {
            case .denseSingleColumn: metrics.exhaustedMinimumSingleColumn
            case .denseGrid: metrics.exhaustedMinimumGrid
            }
        return [
            GridItem(.adaptive(minimum: minimum), spacing: metrics.exhaustedGap, alignment: .top)
        ]
    }

    private var exhaustedSection: some View {
        VStack(alignment: .leading, spacing: metrics.exhaustedGap) {
            Text("Exhausted")
                .font(metrics.exhaustedHeaderFont)
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("exhausted-section-header")
            LazyVGrid(
                columns: exhaustedColumns,
                alignment: .leading,
                spacing: metrics.exhaustedGap
            ) {
                ForEach(exhaustedProviders, id: \.providerName) { provider in
                    exhaustedCell(provider)
                }
            }
        }
    }

    /// Still tappable through to the detail view: compact is about how much
    /// the row costs on screen, not about withholding the full breakdown from
    /// anyone who wants it.
    private func exhaustedCell(_ provider: ProviderStatus) -> some View {
        VStack(alignment: .leading, spacing: metrics.exhaustedLineGap) {
            Text(provider.providerDisplayName)
                .font(metrics.exhaustedTitleFont)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(earliestResetLabel(provider.windows, now: now) ?? "reset unknown")
                .font(metrics.exhaustedResetFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: metrics.exhaustedRowHeight, alignment: .leading)
        .padding(.horizontal, metrics.cardPadding)
        .padding(.vertical, metrics.exhaustedGap)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: metrics.exhaustedCornerRadius))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedProviderName = provider.providerName
        }
        .accessibilityIdentifier("exhausted-provider-\(provider.providerName)")
    }
}
