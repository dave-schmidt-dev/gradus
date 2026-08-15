import GradusKit
import SwiftUI

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
        if ProviderRetryAccessibility.isCarriedFailure(provider) {
            return false
        }
        if ProviderRetryAccessibility.isRetrying(provider) {
            return false
        }
        if !provider.ok {
            return true
        }
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
