import Foundation
import GradusKit

/// The Mac ranks the snapshot model, which -- unlike `ProviderStatus` -- has
/// no stored `isWarning`/`isDepleted`. It is the *producer* of those fields,
/// not a consumer of them, so it derives both locally.
extension ProviderEntry: RankableProvider {
    var rankingName: String { name }

    var rankingWindows: [ProviderWindow] { windows }

    var rankingIsOK: Bool { ok }

    /// Recomputed with exactly the expression `CloudKitMapping` uses as its own
    /// default for the stored field (`windows.contains { percentIsDepleted(...) }`).
    /// Keeping the two literally identical is what makes the Mac's exhausted
    /// partition and the iPhone's contain the same providers -- derive it any
    /// other way and the two apps disagree about the same snapshot.
    var rankingIsDepleted: Bool {
        windows.contains { percentIsDepleted($0.percentLeft) }
    }

    /// The Mac's half of the union documented on `rankedPartition`. The pace
    /// ramp plays the role `isWarning` plays on iOS: it is this platform's
    /// existing "the system already flagged this" signal, so unioning the local
    /// threshold on top can only add providers to the tier, never demote one
    /// the ramp already placed there.
    func rankingNeedsAttention(localThreshold: Double) -> Bool {
        ProviderTriage.needsAttention(self)
            || windows.contains { localIsUrgent($0, threshold: localThreshold) }
    }
}
