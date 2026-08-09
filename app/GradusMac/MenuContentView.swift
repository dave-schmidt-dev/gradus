import AppKit
import GradusKit
import SwiftUI

/// The geometry used to keep the menu's provider section readable without
/// exceeding the currently usable display area. These values intentionally
/// live with the Mac menu instead of an iOS layout helper: this is a vertical,
/// fixed-width problem, while the iOS helper solves horizontal card packing.
enum MenuVerticalBudget {
    static let minimumReferenceHeight: CGFloat = 520
    /// Use the display's actual usable height before introducing a provider
    /// scrollbar. The content is a status menu, not a fixed-height panel.
    static let maximumReferenceHeight: CGFloat = 1_200
    static let fallbackReferenceHeight: CGFloat = 680
    static let verticalSafetyMargin: CGFloat = 24
    /// Menu header, dividers, sync controls, action buttons, and outer padding.
    static let fixedChromeHeight: CGFloat = MenuContentView.fixedChromeHeight
    static let columnWidth: CGFloat = MenuContentView.columnWidth

    static func referenceHeight(visibleScreenHeight: CGFloat?) -> CGFloat {
        guard let visibleScreenHeight, visibleScreenHeight.isFinite else {
            return fallbackReferenceHeight
        }
        return min(
            maximumReferenceHeight,
            max(minimumReferenceHeight, visibleScreenHeight - verticalSafetyMargin)
        )
    }

    /// `visibleFrame` excludes the Dock and menu bar. Read it as the menu is
    /// built rather than caching it: displays can be attached or rearranged
    /// while Gradus is running.
    static var runtimeReferenceHeight: CGFloat {
        referenceHeight(visibleScreenHeight: NSScreen.main?.visibleFrame.height)
    }

    static func providerViewportHeight(for referenceHeight: CGFloat) -> CGFloat {
        max(240, referenceHeight - fixedChromeHeight)
    }

    static func requiredRows(for providers: [ProviderEntry]) -> Int {
        providers.reduce(0) { partial, provider in
            // One provider heading plus every provider window. Task 9.2 turns
            // that window count into rendered rows; the budget must already
            // account for all of them so that change cannot reintroduce clipping.
            partial + 1 + provider.windows.count
        }
    }

    static func resolve(
        providers: [ProviderEntry],
        dynamicTypeSize: DynamicTypeSize,
        referenceHeight: CGFloat
    ) -> MenuDensityResolution {
        let rung = MenuDensityRung.standard
        let rows = requiredRows(for: providers)
        let height = estimatedProviderHeight(for: providers, density: rung, dynamicTypeSize: dynamicTypeSize)
            + fixedChromeHeight
        return MenuDensityResolution(
            rung: rung,
            didFit: height <= referenceHeight,
            requiredRows: rows,
            intrinsicHeight: height,
            referenceHeight: referenceHeight
        )
    }

    /// Mirrors the single-column menu layout below. Every bucket has persistent
    /// reset and pace metadata, regardless of its severity color.
    private static func estimatedProviderHeight(
        for providers: [ProviderEntry],
        density: MenuDensityRung,
        dynamicTypeSize: DynamicTypeSize
    ) -> CGFloat {
        let scale = density.dynamicTypeScale(dynamicTypeSize)
        let active = providers.filter { !$0.rankingIsDepleted }
        let exhausted = providers.filter(\.rankingIsDepleted)
        let activeHeight = columnHeight(active, density: density)
        let exhaustedHeight = exhausted.isEmpty
            ? 0
            : density.exhaustionHeadingHeight + density.providerSpacing
                + columnHeight(exhausted, density: density)
        let sectionSpacing: CGFloat = active.isEmpty || exhausted.isEmpty ? 0 : density.providerSpacing
        return (activeHeight + sectionSpacing + exhaustedHeight) * scale
    }

    private static func columnHeight(_ providers: [ProviderEntry], density: MenuDensityRung) -> CGFloat {
        let providerHeights = providers.map { providerHeight($0, density: density) }
        let spacing = CGFloat(max(0, providers.count - 1)) * density.providerSpacing
        return providerHeights.reduce(0, +) + spacing
    }

    private static func providerHeight(_ provider: ProviderEntry, density: MenuDensityRung) -> CGFloat {
        if provider.ok, provider.windows.count <= 1 {
            return density.singleWindowHeight
        }
        let windowsHeight = CGFloat(provider.windows.count) * density.windowHeight
        let errorHeight = provider.ok ? 0 : density.metadataHeight
        return density.providerHeaderHeight + windowsHeight + errorHeight
    }
}

/// There is deliberately one presentation density. A constrained display can
/// scroll, but it must not reduce type or bars beneath usable dimensions.
enum MenuDensityRung: Equatable {
    case standard

    var rowSpacing: CGFloat { MenuContentView.providerRowSpacing }
    var barHeight: CGFloat { MenuContentView.providerBarHeight }
    var providerSpacing: CGFloat { MenuContentView.providerGroupSpacing }
    var metadataFontKind: MenuMetadataFont { MenuContentView.providerMetadataFont }

    var metadataFont: Font {
        switch metadataFontKind {
        case .caption: .caption
        }
    }

    var providerHeaderHeight: CGFloat { 20 }
    var singleWindowHeight: CGFloat { 48 }
    var windowHeight: CGFloat { 48 }
    var metadataHeight: CGFloat { 20 }
    var exhaustionHeadingHeight: CGFloat { 20 }

    func dynamicTypeScale(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.88
        case .small: 0.94
        case .medium: 1
        case .large: 1.08
        case .xLarge: 1.16
        case .xxLarge: 1.24
        case .xxxLarge: 1.32
        case .accessibility1: 1.42
        case .accessibility2: 1.54
        case .accessibility3: 1.66
        case .accessibility4: 1.78
        case .accessibility5: 1.9
        @unknown default: 1.9
        }
    }
}

enum MenuMetadataFont: Equatable {
    case caption
}

struct MenuDensityResolution: Equatable {
    let rung: MenuDensityRung
    let didFit: Bool
    let requiredRows: Int
    let intrinsicHeight: CGFloat
    let referenceHeight: CGFloat

    var scrolls: Bool { !didFit }
}

/// Applies the density decision before the provider content enters the menu.
/// The false arm deliberately has a fixed viewport: a `ScrollView` allowed to
/// take its content height would still make the popover overflow.
struct MenuProviderListView: View {
    let providers: [ProviderEntry]
    let now: Date
    let sortOption: ProviderSortOption
    let localThreshold: Double
    let availableMenuHeight: CGFloat?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        providers: [ProviderEntry],
        now: Date = Date(),
        sortOption: ProviderSortOption = .mostUrgent,
        localThreshold: Double = PublisherViewModel.defaultLocalWarningThresholdPercent,
        availableMenuHeight: CGFloat? = nil
    ) {
        self.providers = providers
        self.now = now
        self.sortOption = sortOption
        self.localThreshold = localThreshold
        self.availableMenuHeight = availableMenuHeight
    }

    private var resolution: MenuDensityResolution {
        MenuVerticalBudget.resolve(
            providers: providers,
            dynamicTypeSize: dynamicTypeSize,
            referenceHeight: availableMenuHeight ?? MenuVerticalBudget.runtimeReferenceHeight
        )
    }

    var body: some View {
        if resolution.didFit {
            providerList
        } else {
            ScrollView {
                providerList.padding(.bottom, 1)
            }
            .frame(height: MenuVerticalBudget.providerViewportHeight(for: resolution.referenceHeight))
            .accessibilityIdentifier("menu-provider-list-scroll")
        }
    }

    private var providerList: some View {
        ProviderListView(
            providers: providers,
            now: now,
            sortOption: sortOption,
            localThreshold: localThreshold,
            density: resolution.rung
        )
    }
}

/// The MenuBarExtra's dropdown content: one row per provider plus a settings
/// section (sync toggle, launch-at-login, quit). Renders entirely from
/// `PublisherViewModel`'s published state -- no direct CloudKit/file
/// dependency -- so it can be snapshot-tested standalone (T2b.1/T2b.4:
/// XCUITest can't drive a `LSUIElement` status item, so `swift-snapshot-
/// testing` against this view rendered offscreen is the gate instead).
///
/// **This view only renders as written when the scene uses
/// `.menuBarExtraStyle(.window)`.** Under the default `.menu` style SwiftUI
/// does not draw the view tree at all -- it translates it into `NSMenu`
/// items, which flattens every `HStack`, drops custom shapes (the bars
/// below), and replaces the ramp colors with menu text styling. That is not a
/// theoretical caveat: the bars and colors here shipped on 2026-08-05 and had
/// never once been visible, because `GradusMacApp` declared the scene without
/// a style. See that file for the regression note.
struct MenuContentView: View {
    static let columnWidth: CGFloat = 340
    static let fixedChromeHeight: CGFloat = 152
    static let providerRowSpacing: CGFloat = 5
    static let providerBarHeight: CGFloat = 8
    static let providerGroupSpacing: CGFloat = 10
    static let providerMetadataFont: MenuMetadataFont = .caption
    /// Every capacity bar shares the menu's left rail. Window labels carry
    /// hierarchy through their text, not by shifting their bar geometry.
    static let providerBarLeadingInset: CGFloat = 0

    /// A provider remains the heading for a single-window card. Window IDs
    /// describe quota mechanics (for example `premium` or `billing_cycle`),
    /// not subscription plans, so they belong in the reset-and-pace context
    /// rather than being promoted into the provider name.
    static func compactProviderLabel(providerName: String) -> String {
        providerName
    }

    @ObservedObject var viewModel: PublisherViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MenuHeader(
                providers: visibleProviders,
                localThreshold: viewModel.localWarningThresholdPercent
            )

            MenuProviderListView(
                providers: visibleProviders,
                sortOption: viewModel.providerSortOption,
                localThreshold: viewModel.localWarningThresholdPercent
            )
            .id(viewModel.presentationRevision)

            Divider()

            Toggle("Enable iCloud Sync", isOn: $viewModel.syncEnabled)
            if viewModel.syncEnabled {
                cloudSyncStatus
            }
            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { viewModel.launchAtLoginEnabled },
                    set: { viewModel.setLaunchAtLogin($0) }
                )
            )

            Divider()

            Button("Settings…") { SettingsWindow.show(viewModel: viewModel) }
            Button("Quit Gradus") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: MenuVerticalBudget.columnWidth)
    }

    /// Applied here rather than in `PublisherViewModel.providers`, which is the
    /// mirror image of where iOS filters. On iOS that array feeds only the
    /// dashboard, so filtering at the model is the same thing. Here it also
    /// feeds `MenuHeader`'s attention count, and both must agree -- a header
    /// reading "3 need attention" above two rows is worse than either choice.
    /// Filtering once, at the point both are built, keeps them consistent
    /// without letting a display preference reach anything that alerts:
    /// the menu bar icon is computed from the publish payload in
    /// `GradusMacApp`, not from this array, so hiding a spent provider from
    /// the list never quiets the icon for it.
    ///
    /// Internal rather than private so the filter has a direct test. The
    /// alternative was a snapshot, which would prove a row is absent but not
    /// *why* -- and a filter that silently passed everything looks identical to
    /// a preference defaulting to on.
    var visibleProviders: [ProviderEntry] {
        viewModel.showExhausted
            ? viewModel.providers
            : viewModel.providers.filter { !$0.rankingIsDepleted }
    }

    /// "iCloud sync complete" answered the wrong question -- it reported the
    /// outcome of an event the user did not see and could not date. The
    /// timestamp answers "is what I'm looking at current", which is the only
    /// reason to read this line. `.idle` shows it too: the state enum resets
    /// on launch, so a long-running agent would otherwise show nothing at all
    /// despite having synced minutes earlier.
    @ViewBuilder
    private var cloudSyncStatus: some View {
        switch viewModel.syncState {
        case .publishing:
            Text("Syncing with iCloud…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            VStack(alignment: .leading, spacing: 1) {
                Text("iCloud sync failed. Will retry with the next update.")
                    .foregroundStyle(SignalColor.forLevel(.red))
                // A failure is only actionable next to how stale it left you.
                if let label = Self.lastSyncLabel(viewModel.lastSyncedAt) {
                    Text(label).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        case .idle, .synced:
            Text(Self.lastSyncLabel(viewModel.lastSyncedAt) ?? "Not synced yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Uses `friendlyDateLabel` -- the same helper behind the "resets …" copy
    /// on each row -- so the menu never shows two date vocabularies at once.
    static func lastSyncLabel(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        return "Last sync \(friendlyDateLabel(date, now: now))"
    }
}

/// The live `MenuBarExtra` root owns observation of the process-lifetime
/// model. `MenuContentView` remains an observed child because tests construct
/// it directly, outside a mounted SwiftUI hierarchy.
struct MenuBarContentRoot: View {
    @StateObject private var viewModel: PublisherViewModel

    init(viewModel: PublisherViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        MenuContentView(viewModel: viewModel)
    }
}

/// Title plus an at-a-glance count of providers needing attention, so the
/// answer to "is anything wrong" is available without reading any row.
struct MenuHeader: View {
    let providers: [ProviderEntry]
    let localThreshold: Double

    init(
        providers: [ProviderEntry],
        localThreshold: Double = PublisherViewModel.defaultLocalWarningThresholdPercent
    ) {
        self.providers = providers
        self.localThreshold = localThreshold
    }

    /// Counted with the same predicate that decides ranking tier, so the badge
    /// can never disagree with the order below it about what "low" means.
    private var attentionCount: Int {
        providers.filter { $0.rankingNeedsAttention(localThreshold: localThreshold) }.count
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Gradus")
                .font(.headline)
            Spacer()
            if attentionCount > 0 {
                Text("\(attentionCount) low")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SignalColor.forLevel(.red))
            } else {
                Text("all healthy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Ordering and severity rules, kept out of the views so both the row and the
/// header agree on what "needs attention" means without duplicating it.
enum ProviderTriage {
    /// The window closest to depletion -- the one worth surfacing at a glance
    /// in a compact menu row.
    static func worstWindow(_ provider: ProviderEntry) -> ProviderWindow? {
        provider.windows.min { $0.percentLeft < $1.percentLeft }
    }

    /// Attention means the shared ramp classified *any* window orange or red.
    /// Deliberately delegates to `signalLevel` rather than testing a
    /// percentage: the ramp classifies by *pace*, so a window at 1% five
    /// minutes before it resets is fine and must not be flagged.
    ///
    /// It asks about every window, not just `worstWindow`. Until 2026-08-06 it
    /// asked only about the worst-by-percentage one, which is not the same
    /// question: a provider with a 5%-left window sitting on pace and an
    /// 80%-left window burning at -0.5 has nothing wrong with its worst window
    /// and something badly wrong with the other. iOS had always used
    /// any-window, so that provider raised a warning on the phone and none on
    /// the Mac.
    static func needsAttention(_ provider: ProviderEntry) -> Bool {
        if !provider.ok { return true }
        return providerNeedsAttention(provider.windows)
    }

}
// Ordering deliberately does NOT live here any more. `ProviderTriage.sorted`
// ranked by signal level, and because a depleted provider is red, it sorted
// exhausted providers to the *top* -- while iOS's ranking put them last, on
// purpose. Same snapshot, opposite answer, for as long as the two platforms
// each owned a private copy of the rule. Both now call the one
// `rankedPartition` in `Shared/ProviderRanking.swift`; this type keeps only
// the Mac-specific pace-ramp classification that feeds it.

/// The provider rows, split out from `MenuContentView` so they can be
/// snapshot-tested standalone. Multi-window providers use a provider heading
/// and labeled bucket rows; singleton providers compose both names in one
/// compact header. The menu stays a single ordered column so the visual order
/// always matches the selected sort without reserving empty grid cells.

struct ProviderListView: View {
    let providers: [ProviderEntry]
    let now: Date
    let sortOption: ProviderSortOption
    let localThreshold: Double
    let density: MenuDensityRung

    init(
        providers: [ProviderEntry],
        now: Date = Date(),
        sortOption: ProviderSortOption = .mostUrgent,
        localThreshold: Double = PublisherViewModel.defaultLocalWarningThresholdPercent,
        density: MenuDensityRung = .standard
    ) {
        self.providers = providers
        self.now = now
        self.sortOption = sortOption
        self.localThreshold = localThreshold
        self.density = density
    }

    private var ranked: RankedProviders<ProviderEntry> {
        rankedPartition(providers, localThreshold: localThreshold, sortOption: sortOption)
    }

    var body: some View {
        if providers.isEmpty {
            Text("No snapshot data yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let ranked = ranked
            VStack(alignment: .leading, spacing: density.providerSpacing) {
                activeProviders(ranked.active)
                if !ranked.exhausted.isEmpty {
                    ExhaustedProviderSection(providers: ranked.exhausted, now: now, density: density)
                }
            }
        }
    }

    @ViewBuilder
    private func activeProviders(_ providers: [ProviderEntry]) -> some View {
        ForEach(providers, id: \.name) { provider in
            ProviderRow(provider: provider, now: now, density: density)
        }
    }
}

/// Providers with nothing left stay at the bottom, but retain the same provider
/// header and per-window rows as active providers. The menu's information
/// contract is the same for every provider: one header plus every window.
private struct ExhaustedProviderSection: View {
    let providers: [ProviderEntry]
    let now: Date
    let density: MenuDensityRung

    var body: some View {
        VStack(alignment: .leading, spacing: density.rowSpacing + 1) {
            Divider()
            Text("Exhausted")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            ForEach(providers, id: \.name) { provider in
                ProviderRow(provider: provider, now: now, density: density)
            }
        }
    }
}

/// One provider. Every bucket renders the same label, bar, reset, and pace
/// structure. Severity changes color, never whether a bucket explains itself.
private struct ProviderRow: View {
    /// Declared here rather than inline because the metadata line below has to
    /// clear the expected-remaining marker, which is deliberately taller than
    /// the bar so it reads as a tick rather than a segment. Without reserving
    /// that overhang the "resets …" text visually touches the marker.
    let provider: ProviderEntry
    let now: Date
    let density: MenuDensityRung

    @ViewBuilder
    var body: some View {
        if provider.ok, provider.windows.count == 1 {
            compactWindow(provider.windows[0])
        } else {
            expandedWindows
        }
    }

    private func compactWindow(_ window: ProviderWindow) -> some View {
        VStack(alignment: .leading, spacing: density.rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MenuContentView.compactProviderLabel(providerName: provider.name))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(percentDisplay(window.percentLeft))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(SignalColor.forWindow(window))
            }

            ProgressBar(
                fraction: max(0, min(100, window.percentLeft)) / 100,
                markerFraction: ProgressBar.expectedRemainingMarkerFraction(
                    percentLeft: window.percentLeft,
                    paceDelta: window.paceDelta
                ),
                tint: SignalColor.forWindow(window)
            )
            .frame(height: density.barHeight)

            MenuWindowMetadata(window: window, now: now, density: density)
        }
    }

    private var expandedWindows: some View {
        VStack(alignment: .leading, spacing: density.rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(provider.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if provider.windows.isEmpty {
                    Text("—")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(provider.ok ? .secondary : SignalColor.forLevel(.red))
                }
            }

            if !provider.ok {
                Text(provider.error ?? "Provider probe failed")
                    .font(.caption)
                    .foregroundStyle(SignalColor.forLevel(.red))
                    .lineLimit(2)
            }

            if provider.windows.isEmpty, provider.ok {
                Text("no window data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(provider.windows, id: \.id) { window in
                    MenuWindowRow(provider: provider, window: window, now: now, density: density)
                }
            }
        }
    }

}

private struct MenuWindowRow: View {
    let provider: ProviderEntry
    let window: ProviderWindow
    let now: Date
    let density: MenuDensityRung

    var body: some View {
        VStack(alignment: .leading, spacing: density.rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ProviderWindowLabel.label(for: window.id))
                    .font(density.metadataFont.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(percentDisplay(window.percentLeft))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(SignalColor.forWindow(window))
            }

            ProgressBar(
                fraction: max(0, min(100, window.percentLeft)) / 100,
                markerFraction: ProgressBar.expectedRemainingMarkerFraction(
                    percentLeft: window.percentLeft,
                    paceDelta: window.paceDelta
                ),
                tint: SignalColor.forWindow(window)
            )
            .frame(height: density.barHeight)

            MenuWindowMetadata(window: window, now: now, density: density)
        }
        .padding(.leading, MenuContentView.providerBarLeadingInset)
    }

}

struct MenuWindowMetadata: View {
    let window: ProviderWindow
    let now: Date
    let density: MenuDensityRung

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.resetLabel(for: window, now: now))
            Spacer(minLength: 4)
            Text(Self.paceLabel(for: window))
        }
        .font(density.metadataFont)
        .foregroundStyle(.secondary)
        .padding(.top, ProgressBar.markerOverhang(barHeight: density.barHeight))
    }

    static func resetLabel(for window: ProviderWindow, now: Date) -> String {
        guard let resetISO = window.resetISO else { return "reset unavailable" }
        return "resets \(friendlyResetDate(resetISO, now: now) ?? resetISO)"
    }

    static func paceLabel(for window: ProviderWindow) -> String {
        guard let paceDelta = window.paceDelta, paceDelta.isFinite else { return "pace unavailable" }
        let points = abs(paceDelta * 100).rounded()
        if points < 1 { return "on pace" }
        return "\(Int(points))% \(paceDelta < 0 ? "behind" : "ahead")"
    }
}

/// Hand-drawn in place of `ProgressView`: the native control is AppKit-
/// representable-backed and doesn't rasterize under `ImageRenderer`
/// offscreen. A plain `Capsule` fill renders identically in the live app
/// and under the snapshot gate.
struct ProgressBar: View {
    private static let markerWidth: CGFloat = 3

    let fraction: Double
    let markerFraction: Double?
    let tint: Color

    /// The marker stays inside the bar. A marker taller than its bar made rows
    /// with a pace reference appear visually thicker than rows without one.
    static func markerOverhang(barHeight: CGFloat) -> CGFloat {
        0
    }

    /// The expected-remaining marker uses the shared kit calculation so the
    /// compact Mac row stays aligned with the other Gradus surfaces.
    static func expectedRemainingMarkerFraction(
        percentLeft: Double?,
        paceDelta: Double?
    ) -> Double? {
        expectedRemaining(percentLeft: percentLeft, paceDelta: paceDelta).map { $0 / 100 }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(tint)
                    .frame(width: geometry.size.width * max(0, min(1, fraction)))
                if let markerFraction {
                    Rectangle()
                        .fill(SignalColor.paceMarker)
                        .frame(width: Self.markerWidth, height: geometry.size.height)
                        .offset(
                            x: markerOffset(
                                fraction: markerFraction,
                                barWidth: geometry.size.width,
                                markerWidth: Self.markerWidth
                            )
                        )
                        .zIndex(1)
                        .accessibilityLabel("Expected remaining")
                }
            }
        }
    }
}
