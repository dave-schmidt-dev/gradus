import GradusKit
import SwiftUI
import UIKit

let dashboardHorizontalInset: CGFloat = 16

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
    let onExploreSample: () -> Void
    let onRetryICloud: () -> Void
    let isSampleEntryInProgress: Bool
    /// Test-only initial state for the explicit permission-requesting UI.
    /// Production callers use the default and derive this state from a user
    /// interaction with Warning alerts.
    let initialWarningAlertsPending: Bool

    init(
        viewModel: DashboardViewModel,
        now: Date = Date(),
        onExploreSample: @escaping () -> Void = {},
        onRetryICloud: @escaping () -> Void = {},
        isSampleEntryInProgress: Bool = false,
        initialWarningAlertsPending: Bool = false
    ) {
        self.viewModel = viewModel
        self.now = now
        self.onExploreSample = onExploreSample
        self.onRetryICloud = onRetryICloud
        self.isSampleEntryInProgress = isSampleEntryInProgress
        self.initialWarningAlertsPending = initialWarningAlertsPending
    }

    var body: some View {
        NavigationStack {
            DashboardContent(
                viewModel: viewModel,
                now: now,
                onExploreSample: onExploreSample,
                onRetryICloud: onRetryICloud,
                isSampleEntryInProgress: isSampleEntryInProgress,
                initialWarningAlertsPending: initialWarningAlertsPending
            )
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

    /// The editorial comfort rule: reset is welcome on the wider presentation
    /// but deliberately omitted from the compact presentation even when the
    /// collapse floor says the column would technically fit.
    var editorialShowsReset: Bool {
        self == .denseGrid
    }
}

/// The provider/window identity that both size classes promise to present.
/// Keeping this semantic shape separate from pixels lets parity tests reject
/// an information split even when the two devices necessarily have different
/// viewport geometry.
struct DashboardProviderWindowSet: Equatable {
    let providerName: String
    let windowIDs: [String]
}

struct DashboardContent: View {
    @ObservedObject var viewModel: DashboardViewModel
    let now: Date

    /// `nil` means "follow the size class". Tests pass an explicit value.
    private let layoutOverride: DashboardLayout?
    /// `nil` means "use the stored preference". Snapshot tests pass an explicit
    /// density so a baseline names the density it depicts rather than depending
    /// on whatever `UserDefaults` the fixture happened to build.
    ///
    /// Not `private`: `DashboardView+DenseGrid.swift`'s grid-resolution
    /// extension reads this from a sibling file within the same module.
    let densityOverride: DashboardDensity?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Not `private`: read by the exhausted-section sizing helpers in
    /// `DashboardView+DenseGrid.swift`.
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    /// Row-tap navigation target (P4/T4.2): set on tap of any
    /// `ProviderDensityCard`, pushing `ProviderDetailView` for that provider.
    /// Same behavior in both layouts (INV-12). Tracked by `providerName`
    /// (not the `ProviderStatus` value itself) since `ProviderStatus` isn't
    /// `Hashable` and `.navigationDestination(item:)` requires that --
    /// looking the provider back up from `viewModel.providers` by name
    /// keeps this file from having to add a `Hashable` conformance to a
    /// `GradusKit` model type for a purely-iOS navigation concern.
    ///
    /// Not `private`: also set from the grid/exhausted-section row taps in
    /// `DashboardView+DenseGrid.swift`.
    @State var selectedProviderName: String?
    /// Settings presentation (P5/T5.3): a sheet rather than a
    /// `navigationDestination` push -- decoupled from the `selectedProviderName`
    /// push-navigation state Phase 4 owns above, and matches the design
    /// system's "one trailing accessory" nav-bar rule without needing
    /// Settings to participate in the same navigation stack as provider
    /// detail drill-in.
    @State private var showingSettings = false
    let isSampleMode: Bool
    let onExploreSample: () -> Void
    let onRetryICloud: () -> Void
    let onExitSample: () -> Void
    let onResetSample: () -> Void
    let isSampleEntryInProgress: Bool
    let initialWarningAlertsPending: Bool

    // The grid must resolve its column count before the child WindowRows are
    // installed. Keep the same compile-time style mapping as WindowRow here;
    // reading a child's @ScaledMetric through a temporary View would use the
    // default environment and silently make the solver ignore Dynamic Type.
    //
    // Not `private`: consumed by the grid-sizing math in
    // `DashboardView+DenseGrid.swift`.
    @ScaledMetric(relativeTo: .caption) var compactLabelWidth = DensityMetrics.compact.labelWidth
    @ScaledMetric(relativeTo: .caption) var compactPercentWidth = DensityMetrics.compact.percentWidth
    @ScaledMetric(relativeTo: .caption2) var compactResetWidth = DensityMetrics.compact.resetWidth
    @ScaledMetric(relativeTo: .footnote) var standardLabelWidth = DensityMetrics.standard.labelWidth
    @ScaledMetric(relativeTo: .footnote) var standardPercentWidth = DensityMetrics.standard.percentWidth
    @ScaledMetric(relativeTo: .caption) var standardResetWidth = DensityMetrics.standard.resetWidth
    @ScaledMetric(relativeTo: .subheadline) var largeLabelWidth = DensityMetrics.large.labelWidth
    @ScaledMetric(relativeTo: .subheadline) var largePercentWidth = DensityMetrics.large.percentWidth
    @ScaledMetric(relativeTo: .footnote) var largeResetWidth = DensityMetrics.large.resetWidth

    init(
        viewModel: DashboardViewModel,
        now: Date = Date(),
        layout: DashboardLayout? = nil,
        density: DashboardDensity? = nil,
        isSampleMode: Bool = false,
        onExploreSample: @escaping () -> Void = {},
        onRetryICloud: @escaping () -> Void = {},
        onExitSample: @escaping () -> Void = {},
        onResetSample: @escaping () -> Void = {},
        isSampleEntryInProgress: Bool = false,
        initialWarningAlertsPending: Bool = false
    ) {
        self.viewModel = viewModel
        self.now = now
        layoutOverride = layout
        densityOverride = density
        self.isSampleMode = isSampleMode
        self.onExploreSample = onExploreSample
        self.onRetryICloud = onRetryICloud
        self.onExitSample = onExitSample
        self.onResetSample = onResetSample
        self.isSampleEntryInProgress = isSampleEntryInProgress
        self.initialWarningAlertsPending = initialWarningAlertsPending
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
                    .accessibilityIdentifier("settings-button")
                }
            }

            Group {
                if let emptyState = viewModel.emptyState {
                    EmptyStateView(
                        state: emptyState,
                        onExploreSample: onExploreSample,
                        onEnableSync: { performICloudRecovery(for: emptyState) },
                        isExploreSampleInProgress: isSampleEntryInProgress
                    )
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
            SettingsView(
                dashboardViewModel: viewModel,
                isSampleMode: isSampleMode,
                onExploreSample: onExploreSample,
                onExitSample: onExitSample,
                onResetSample: onResetSample,
                isSampleEntryInProgress: isSampleEntryInProgress,
                initialWarningAlertsPending: initialWarningAlertsPending
            )
        }
    }

    enum ICloudRecoveryAction: Equatable {
        case confirmRequiredICloud
        case retryLiveLifecycle
        case none
    }

    static func iCloudRecoveryAction(for state: DashboardEmptyState) -> ICloudRecoveryAction {
        switch state {
        case .awaitingConfirmation, .syncDisabled:
            .confirmRequiredICloud
        case .tryAgain, .notSignedIn, .restricted:
            .retryLiveLifecycle
        case .checkingICloud, .waitingForFirstPublish:
            .none
        }
    }

    func performICloudRecovery(for state: DashboardEmptyState) {
        switch Self.iCloudRecoveryAction(for: state) {
        case .confirmRequiredICloud:
            viewModel.confirmRequiredICloud()
        case .retryLiveLifecycle:
            onRetryICloud()
        case .none:
            break
        }
    }

    /// Semantic parity surface for iPhone and iPad snapshots. Ordering is
    /// intentional: it is the row-major provider order users read left to
    /// right, followed by the source window order inside each card.
    var semanticProviderWindowSet: [DashboardProviderWindowSet] {
        viewModel.providers.map {
            DashboardProviderWindowSet(
                providerName: $0.providerName,
                windowIDs: CrossSurfaceParity.visibleWindows($0.windows).map(\.id)
            )
        }
    }
}
