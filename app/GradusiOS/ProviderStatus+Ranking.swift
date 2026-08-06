import Foundation
import GradusKit

/// iOS ranks the CloudKit model, which arrives with `isWarning`/`isDepleted`
/// already stamped on it by the Mac publisher. Both are read straight through
/// rather than recomputed: the publisher's answer is the one the push
/// notification was sent about, and recomputing here could disagree with it.
extension ProviderStatus: RankableProvider {
    var rankingName: String { providerName }

    var rankingWindows: [ProviderWindow] { windows }

    var rankingIsOK: Bool { ok }

    var rankingIsDepleted: Bool { isDepleted }

    /// The union documented on `rankedPartition` (Key decision #6): the stored
    /// `isWarning` guarantees anything CloudKit already pushed about is never
    /// demoted, and the local threshold can only ever add to this tier.
    ///
    /// Since 2026-08-06 the stored field carries `providerNeedsAttention`, the
    /// same function the Mac evaluates locally — so reading it through here is
    /// no longer a *different* answer from the Mac's, just a cheaper one.
    func rankingNeedsAttention(localThreshold: Double) -> Bool {
        isWarning || windows.contains { localIsUrgent($0, threshold: localThreshold) }
    }
}
