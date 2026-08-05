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
            MenuHeader(providers: viewModel.providers)

            ProviderListView(providers: viewModel.providers)

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

            Button("Quit Gradus") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    @ViewBuilder
    private var cloudSyncStatus: some View {
        switch viewModel.syncState {
        case .idle:
            EmptyView()
        case .publishing:
            Text("Syncing with iCloud…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .synced:
            Text("iCloud sync complete")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Text("iCloud sync failed. Will retry with the next update.")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

/// Title plus an at-a-glance count of providers needing attention, so the
/// answer to "is anything wrong" is available without reading any row.
struct MenuHeader: View {
    let providers: [ProviderEntry]

    private var attentionCount: Int {
        providers.filter(ProviderTriage.needsAttention).count
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

    /// Lower rank sorts first: failures, then the ramp worst-to-best.
    private static func rank(_ provider: ProviderEntry) -> Int {
        guard provider.ok else { return 0 }
        guard let window = worstWindow(provider) else { return 5 }
        switch signalLevel(for: window) {
        case .red: return 1
        case .orange: return 2
        case .yellow: return 3
        case .green: return 4
        case .unknown: return 5
        }
    }

    /// Urgency order, so the provider about to run out is never buried
    /// mid-list. Ties break on percentage and then name, which keeps the
    /// order stable across refreshes rather than reshuffling equal rows.
    static func sorted(_ providers: [ProviderEntry]) -> [ProviderEntry] {
        providers.sorted { lhs, rhs in
            let (lrank, rrank) = (rank(lhs), rank(rhs))
            if lrank != rrank { return lrank < rrank }
            let lpct = worstWindow(lhs)?.percentLeft ?? .infinity
            let rpct = worstWindow(rhs)?.percentLeft ?? .infinity
            if lpct != rpct { return lpct < rpct }
            return lhs.name < rhs.name
        }
    }
}

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

    init(providers: [ProviderEntry], now: Date = Date()) {
        self.providers = providers
        self.now = now
    }

    var body: some View {
        if providers.isEmpty {
            Text("No snapshot data yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ProviderTriage.sorted(providers), id: \.name) { provider in
                    ProviderRow(provider: provider, now: now)
                }
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
                .frame(height: 8)
                if ProviderTriage.needsAttention(provider) {
                    metadata(for: window)
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
