import Foundation

/// How current a provider's own observation is, computed from `observedAt`
/// against wall-clock `now` (T3.4/CR-1) -- keys off the provider's actual
/// observation time, not CloudKit `publishedAt`, so a carried-forward entry
/// (e.g. Antigravity under launchd, §5.6) reads as stale even though it was
/// just republished.
public enum ObservationFreshness: Equatable, Sendable {
    case fresh
    case unknown
    case stale(ageDisplay: String)
}

/// Below this age, an observation reads as current and no badge is shown --
/// roughly one missed cycle of the ~120s launchd snapshot refresher
/// (SnapshotWatcher/PublishPipeline), so normal publish cadence never
/// flickers a stale badge.
public let staleThresholdSeconds: TimeInterval = 180

public func freshness(observedAt: String?, now: Date) -> ObservationFreshness {
    guard let observedAt else { return .unknown }

    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let withoutFraction = ISO8601DateFormatter()
    withoutFraction.formatOptions = [.withInternetDateTime]

    guard let observedDate = withFraction.date(from: observedAt) ?? withoutFraction.date(from: observedAt) else {
        return .unknown
    }
    let age = max(0, now.timeIntervalSince(observedDate))
    guard age >= staleThresholdSeconds else { return .fresh }
    return .stale(ageDisplay: formattedAge(age))
}

/// Bucketed age of a known timestamp, in the same `<1m`/`Xm`/`Xh` format
/// `freshness` uses.
///
/// Unlike `freshness` this applies no threshold — it labels any age, including
/// a fresh one. That is what a persistent "synced Xm ago" header needs, where
/// `freshness` would collapse everything under `staleThresholdSeconds` into a
/// single `.fresh` case and lose the number. Shares `formattedAge` with
/// `freshness` rather than restating the buckets, so the header and the stale
/// badge cannot disagree about what "5m" means.
public func ageLabel(since date: Date, now: Date) -> String {
    formattedAge(max(0, now.timeIntervalSince(date)))
}

/// Mirrors the TUI's `(offline Xm)` bucket format (`gradus/ui.py`) so the
/// dashboard reads the same way as the terminal.
private func formattedAge(_ seconds: TimeInterval) -> String {
    let totalSeconds = Int(seconds)
    if totalSeconds < 60 {
        return "<1m"
    }
    if totalSeconds < 3600 {
        return "\(totalSeconds / 60)m"
    }
    return "\(totalSeconds / 3600)h"
}
