import Foundation
import GradusKit

/// Maps a decoded `ProviderEntry` (GradusKit's Python-mirroring model) to
/// the CloudKit-facing `ProviderStatus`. `providerDisplayName` is the same
/// string as `name` — the Python producer already emits human-readable
/// names ("Codex", "Antigravity (Claude)", ...), there is no separate
/// display-name table.
enum SnapshotDataValidationError: Error, Equatable {
    case unsupportedKey(String)
    case nonFiniteNumber(String)
    case valueTooLarge(String)
    case errorMessageTooLarge
    case aggregateTooLarge
}

private let snapshotDataAllowedKeys: Set<String> = [
    "credits",
    "five_hour_percent_left",
    "weekly_percent_left",
    "five_hour_reset",
    "weekly_reset",
    "session_percent_left",
    "opus_percent_left",
    "primary_reset",
    "secondary_reset",
    "opus_reset",
    "usage_percent",
    "reset_at",
    "payg_enabled",
    "start_date",
    "end_date",
    "monthly_percent_left",
    "monthly_reset",
    "auto_percent_used",
    "api_percent_used",
    "billing_cycle_start",
    "billing_cycle_end",
    "billing_cycle_end_iso",
    "premium_percent_left",
    "premium_reset"
]

private let snapshotDataMaxStringBytes = 4096
private let snapshotDataMaxAggregateBytes = 32768
private let snapshotErrorMaxBytes = 4096

func validatedSnapshotData(_ data: [String: JSONValue]) throws -> [String: JSONValue] {
    for (key, value) in data {
        guard snapshotDataAllowedKeys.contains(key) else {
            throw SnapshotDataValidationError.unsupportedKey(key)
        }
        switch value {
        case let .string(string):
            guard string.utf8.count <= snapshotDataMaxStringBytes else {
                throw SnapshotDataValidationError.valueTooLarge(key)
            }
        case let .double(number):
            guard number.isFinite else {
                throw SnapshotDataValidationError.nonFiniteNumber(key)
            }
        case .bool, .null:
            break
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let encoded = try? encoder.encode(data), encoded.count <= snapshotDataMaxAggregateBytes else {
        throw SnapshotDataValidationError.aggregateTooLarge
    }
    return data
}

func makeProviderStatus(
    from entry: ProviderEntry,
    snapshotUpdatedAt: String,
    publishedAt: Date,
    syncSource: SyncSource? = nil
) throws -> ProviderStatus {
    if let error = entry.error, error.utf8.count > snapshotErrorMaxBytes {
        throw SnapshotDataValidationError.errorMessageTooLarge
    }
    return try ProviderStatus(
        providerName: entry.name,
        providerDisplayName: entry.name,
        ok: entry.ok,
        errorMessage: entry.error,
        windows: entry.windows,
        data: validatedSnapshotData(entry.data),
        observedAt: entry.observedAt,
        snapshotUpdatedAt: snapshotUpdatedAt,
        publishedAt: publishedAt,
        syncSource: syncSource
    )
}
