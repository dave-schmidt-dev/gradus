import GradusKit
import SwiftUI

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
    @ObservedObject var viewModel: PublisherViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MenuHeader(
                providers: visibleProviders,
                localThreshold: viewModel.localWarningThresholdPercent
            )

            ProviderListView(
                providers: visibleProviders,
                sortOption: viewModel.providerSortOption,
                localThreshold: viewModel.localWarningThresholdPercent
            )

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
        .frame(width: 280)
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

    /// Attention means the shared ramp classified the row orange or red.
    /// Deliberately delegates to `signalLevel` rather than testing a
    /// percentage: the ramp classifies by *pace*, so a window at 1% five
    /// minutes before it resets is fine and must not be flagged.
    static func needsAttention(_ provider: ProviderEntry) -> Bool {
        if !provider.ok { return true }
        guard let window = worstWindow(provider) else { return false }
        switch signalLevel(for: window) {
        case .orange, .red: return true
        case .green, .yellow, .unknown: return false
        }
    }

}
// Ordering deliberately does NOT live here any more. `ProviderTriage.sorted`
// ranked by signal level, and because a depleted provider is red, it sorted
// exhausted providers to the *top* -- while iOS's ranking put them last, on
// purpose. Same snapshot, opposite answer, for as long as the two platforms
// each owned a private copy of the rule. Both now call the one
// `rankedPartition` in `Shared/ProviderRanking.swift`; this type keeps only
// the Mac-specific pace-ramp classification that feeds it.

/// The provider rows, split out from `MenuContentView` so it can be
/// snapshot-tested standalone. `Toggle` and the native `ProgressView` are
/// AppKit-representable-backed and don't rasterize under `ImageRenderer`
/// without a live window (they render as a placeholder glyph offscreen);
/// this subview sticks to Text and plain SwiftUI shapes, which do render
/// correctly. The interactive controls stay in `MenuContentView` for the
/// real app and are covered by the plan's manual status-item check instead.
struct ProviderListView: View {
    let providers: [ProviderEntry]
    let now: Date
    let sortOption: ProviderSortOption
    let localThreshold: Double

    init(
        providers: [ProviderEntry],
        now: Date = Date(),
        sortOption: ProviderSortOption = .mostUrgent,
        localThreshold: Double = PublisherViewModel.defaultLocalWarningThresholdPercent
    ) {
        self.providers = providers
        self.now = now
        self.sortOption = sortOption
        self.localThreshold = localThreshold
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
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ranked.active, id: \.name) { provider in
                    ProviderRow(provider: provider, now: now)
                }
                if !ranked.exhausted.isEmpty {
                    ExhaustedProviderSection(providers: ranked.exhausted, now: now)
                }
            }
        }
    }
}

/// Providers with nothing left, in the one place they belong: the bottom, in
/// the least amount of space that still answers the only question a spent
/// provider raises -- when does it come back.
///
/// A depleted provider is the *least* actionable row in the menu: there is no
/// pace to correct and no budget to spend. Rendering it with the same name +
/// percentage + bar + metadata as an active provider spends four lines saying
/// "0%" and pushes the rows that can still be acted on off the top. Name and
/// reset time, one line each, is the whole payload.
private struct ExhaustedProviderSection: View {
    let providers: [ProviderEntry]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Exhausted")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            ForEach(providers, id: \.name) { provider in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(provider.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let reset = earliestResetLabel(provider.windows, now: now) {
                        Text(reset).monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("exhausted-provider-\(provider.name)")
            }
        }
    }
}

/// One provider. Healthy rows are name + percentage + bar; only rows needing
/// attention pay for the third metadata line.
///
/// The asymmetry is the point. Eight providers at four lines each produced a
/// menu taller than the screen in which every line was styled identically, so
/// the one number that mattered (a provider at 0%) looked exactly like the
/// seven that didn't. Reset time and pace answer "when" and "how fast", which
/// are only worth screen space once "how much is left" is alarming.
private struct ProviderRow: View {
    /// Declared here rather than inline because the metadata line below has to
    /// clear the expected-remaining marker, which is deliberately taller than
    /// the bar so it reads as a tick rather than a segment. Without reserving
    /// that overhang the "resets …" text visually touches the marker.
    private static let barHeight: CGFloat = 8

    let provider: ProviderEntry
    let now: Date

    private var worstWindow: ProviderWindow? { ProviderTriage.worstWindow(provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !provider.ok {
                header(value: "error", tint: SignalColor.forLevel(.red))
                Text(provider.error ?? "Provider probe failed")
                    .font(.caption2)
                    .foregroundStyle(SignalColor.forLevel(.red))
                    .lineLimit(2)
            } else if let window = worstWindow {
                let tint = SignalColor.forWindow(window)
                header(value: "\(Int(window.percentLeft))%", tint: tint)
                ProgressBar(
                    fraction: max(0, min(100, window.percentLeft)) / 100,
                    markerFraction: ProgressBar.expectedRemainingMarkerFraction(
                        percentLeft: window.percentLeft,
                        paceDelta: window.paceDelta
                    ),
                    tint: tint
                )
                .frame(height: Self.barHeight)
                if ProviderTriage.needsAttention(provider) {
                    metadata(for: window)
                        .padding(.top, ProgressBar.markerOverhang(barHeight: Self.barHeight))
                }
            } else {
                header(value: "—", tint: .secondary)
                Text("no window data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Name left, value right. The percentage carries the ramp color and the
    /// heavier weight because it is the number the row exists to communicate;
    /// monospaced digits keep the column aligned down the whole list.
    private func header(value: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(provider.name)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
    }

    private func metadata(for window: ProviderWindow) -> some View {
        HStack(spacing: 8) {
            if let resetISO = window.resetISO {
                Text("resets \(friendlyResetDate(resetISO, now: now) ?? resetISO)")
            }
            Spacer(minLength: 4)
            if let pace = paceLabel(window.paceDelta) {
                Text(pace)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// "21% behind" reads as a state; "pace -21%" asks the reader to work out
    /// what the sign means. Same number, no decoding step.
    private func paceLabel(_ paceDelta: Double?) -> String? {
        guard let paceDelta, paceDelta.isFinite else { return nil }
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
    private static let markerHeight: CGFloat = 14

    let fraction: Double
    let markerFraction: Double?
    let tint: Color

    /// How far the marker sticks out past each edge of a bar of the given
    /// height. Callers stacking content directly under a bar need this as
    /// padding, otherwise the marker collides with whatever follows -- the
    /// marker is drawn from the bar's center line and is intentionally taller
    /// than the bar itself.
    static func markerOverhang(barHeight: CGFloat) -> CGFloat {
        max(0, (markerHeight - barHeight) / 2)
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
                        .fill(Color.red)
                        .frame(width: Self.markerWidth, height: Self.markerHeight)
                        .offset(
                            x: geometry.size.width * max(0, min(1, markerFraction))
                                - Self.markerWidth / 2
                        )
                        .zIndex(1)
                        .accessibilityLabel("Expected remaining")
                }
            }
        }
    }
}
