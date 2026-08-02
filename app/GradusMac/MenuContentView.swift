import GradusKit
import SwiftUI

/// The MenuBarExtra's dropdown content: one compact row per provider plus a
/// settings section (sync toggle, launch-at-login, quit). Renders entirely
/// from `PublisherViewModel`'s published state -- no direct CloudKit/file
/// dependency -- so it can be snapshot-tested standalone (T2b.1/T2b.4:
/// XCUITest can't drive a `LSUIElement` status item, so `swift-snapshot-
/// testing` against this view rendered offscreen is the gate instead).
struct MenuContentView: View {
    @ObservedObject var viewModel: PublisherViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gradus")
                .font(.headline)

            ProviderListView(providers: viewModel.providers)

            Divider()

            Toggle("Enable iCloud Sync", isOn: $viewModel.syncEnabled)
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
        .frame(width: 260)
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

    var body: some View {
        if providers.isEmpty {
            Text("No snapshot data yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(providers, id: \.name) { provider in
                ProviderRow(provider: provider)
            }
        }
    }
}

private struct ProviderRow: View {
    let provider: ProviderEntry

    /// The window closest to depletion -- the one worth surfacing at a
    /// glance in a compact menu row.
    private var worstWindow: ProviderWindow? {
        provider.windows.min { ($0.percentLeft) < ($1.percentLeft) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(provider.name)
                .font(.subheadline.bold())

            if !provider.ok {
                Text(provider.error ?? "error")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let window = worstWindow {
                HStack {
                    ProgressBar(
                        fraction: max(0, min(100, window.percentLeft)) / 100,
                        tint: windowWarns(window) ? .orange : .green
                    )
                    .frame(height: 6)
                    Text("\(Int(window.percentLeft))%")
                        .font(.caption.monospacedDigit())
                }
                HStack(spacing: 8) {
                    if let resetISO = window.resetISO {
                        Text("reset \(resetISO)")
                    }
                    if let pace = window.paceDelta {
                        Text(String(format: "pace %+.0f%%", pace * 100))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text("no window data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Hand-drawn in place of `ProgressView`: the native control is AppKit-
/// representable-backed and doesn't rasterize under `ImageRenderer`
/// offscreen. A plain `Capsule` fill renders identically in the live app
/// and under the snapshot gate.
private struct ProgressBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(tint)
                    .frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }
    }
}
