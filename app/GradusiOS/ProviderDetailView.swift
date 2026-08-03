import GradusKit
import SwiftUI

/// Provider Detail screen (P4/T4.2), pushed from a Now-screen row/hero tap
/// (`DashboardContent.selectedProviderName`): renders every window in
/// `provider.windows` at full size -- not just the single worst one
/// `StatTile` shows on the Now screen -- using `ProviderWindowLabel` (P4/T4.1)
/// to distinguish them.
///
/// Provenance footer shows only `observed: <freshness()-derived age>`. The
/// `Screens.jsx` mockup's `source: api` / `schema: v2` shields are
/// deliberately dropped, not ported: `ProviderStatus`
/// (`GradusKit/CloudKitMapping.swift`) carries no `source`/`schema` field --
/// those two labels are static mockup decoration with no backing data on
/// this codebase's actual record type.
struct ProviderDetailView: View {
    let provider: ProviderStatus
    let now: Date

    init(provider: ProviderStatus, now: Date = Date()) {
        self.provider = provider
        self.now = now
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(provider.providerDisplayName)
                    .font(.title2.bold())

                windowsBody

                Divider()

                Text(observedFooterText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(provider.providerDisplayName)
    }

    @ViewBuilder
    private var windowsBody: some View {
        if !provider.ok {
            Text(provider.errorMessage ?? "error")
                .font(.subheadline)
                .foregroundStyle(.red)
        } else if provider.windows.isEmpty {
            Text("no window data")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(provider.windows.enumerated()), id: \.offset) { _, window in
                    windowCard(window)
                }
            }
        }
    }

    @ViewBuilder
    private func windowCard(_ window: ProviderWindow) -> some View {
        let percent = max(0, min(100, window.percentLeft))
        let color = SignalColor.forPercent(window.percentLeft)

        VStack(alignment: .leading, spacing: 6) {
            Text(ProviderWindowLabel.label(for: window.id))
                .font(.headline)

            HStack {
                ProgressView(value: percent / 100)
                    .tint(color)
                Text("\(Int(window.percentLeft))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(color)
            }

            HStack(spacing: 12) {
                if let resetISO = window.resetISO {
                    Text("reset \(resetISO)")
                }
                if let pace = window.paceDelta {
                    Text(String(format: "pace %+.0f%%", pace * 100))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    /// Renders `freshness(observedAt:now:)`'s result as plain text -- the
    /// only provenance the footer shows (see file doc comment). `.fresh`
    /// carries no numeric age of its own (it just means "under the stale
    /// threshold"), so it reads as "just now" rather than a fabricated
    /// number; `.stale`'s `ageDisplay` and `.unknown` render as-is.
    private var observedFooterText: String {
        switch freshness(observedAt: provider.observedAt, now: now) {
        case .fresh:
            return "observed: just now"
        case .stale(let ageDisplay):
            return "observed: \(ageDisplay) ago"
        case .unknown:
            return "observed: unknown"
        }
    }
}
