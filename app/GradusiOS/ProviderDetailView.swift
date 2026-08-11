import GradusKit
import SwiftUI

/// Provider Detail screen (P4/T4.2), pushed from a Now-screen row/hero tap
/// (`DashboardContent.selectedProviderName`): renders every window in
/// `provider.windows` at full size, using `ProviderWindowLabel` (P4/T4.1) to
/// distinguish them. This was the only surface showing every window while the
/// Now screen showed just the worst one per provider; since the dense layout
/// (INV-12) it is the full-size view of what the Now screen shows densely.
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
        if !provider.windows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(provider.windows.enumerated()), id: \.offset) { _, window in
                    windowCard(window)
                }
                if !provider.ok {
                    errorText
                }
            }
        } else if !provider.ok {
            errorText
        } else {
            Text("no window data")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var errorText: some View {
        let label = IOSProviderRetryAccessibility.displayLabel(for: provider)
        return Text(label)
            .font(.subheadline)
            .foregroundStyle(
                IOSProviderRetryAccessibility.isRetrying(provider) ? Color.secondary : Color.red
            )
            .accessibilityLabel(label)
    }

    @ViewBuilder
    private func windowCard(_ window: ProviderWindow) -> some View {
        let color = SignalColor.forWindow(window)

        VStack(alignment: .leading, spacing: 6) {
            Text(ProviderWindowLabel.label(for: window.id))
                .font(.headline)

            HStack {
                UsageBar(window: window, color: color)
                Text(percentDisplay(window.percentLeft))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(color)
            }

            HStack(spacing: 12) {
                if let resetISO = window.resetISO {
                    Text("reset \(friendlyResetDate(resetISO, now: now) ?? resetISO)")
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
