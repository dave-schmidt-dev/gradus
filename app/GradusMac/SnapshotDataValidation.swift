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
    "credit_balance",
    "zen_credit",
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

/// Optional CloudKit dataJSON evidence. Its source time is independent of the
/// usage snapshot time, so a later unjoined snapshot may carry this last
/// observed value without claiming it is a fresh count.
struct BankedResetEvidence: Equatable {
    let count: Int
    let generation: UUID
    let observedAt: String
    let observedDate: Date

    var data: [String: JSONValue] {
        [
            "banked_reset_count": .double(Double(count)),
            "banked_reset_generation": .string(generation.uuidString.lowercased()),
            "banked_reset_observed_at": .string(observedAt)
        ]
    }

    init?(count: Int, generation: String, observedAt: String) {
        guard (0 ... BankedObservation.maximumCount).contains(count),
              let parsedGeneration = UUID(uuidString: generation),
              parsedGeneration.uuidString.lowercased() == generation,
              let date = Self.parseTimestamp(observedAt)
        else { return nil }
        self.count = count
        self.generation = parsedGeneration
        self.observedAt = observedAt
        observedDate = date
    }

    init?(data: [String: JSONValue]) {
        guard case let .double(rawCount)? = data["banked_reset_count"],
              rawCount.isFinite, rawCount.rounded() == rawCount,
              rawCount >= 0, rawCount <= Double(BankedObservation.maximumCount),
              case let .string(rawGeneration)? = data["banked_reset_generation"],
              let generation = UUID(uuidString: rawGeneration),
              generation.uuidString.lowercased() == rawGeneration,
              case let .string(observedAt)? = data["banked_reset_observed_at"]
        else { return nil }
        self.init(count: Int(rawCount), generation: generation.uuidString.lowercased(), observedAt: observedAt)
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

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

/// Validate the raw producer allowlist first, then add only the three
/// optional Codex fields. An oversized augmentation falls back to the exact
/// raw data, yielding the same content hash on repeated attempts.
func validatedAugmentedSnapshotData(
    _ rawData: [String: JSONValue], bankedObservation: BankedObservation?
) throws -> [String: JSONValue] {
    let validated = try validatedSnapshotData(rawData)
    guard let bankedObservation,
          let evidence = BankedResetEvidence(
              count: bankedObservation.count,
              generation: bankedObservation.generation,
              observedAt: bankedObservation.observedAt
          )
    else { return validated }
    return addingBankedEvidence(evidence, to: validated)
}

func addingBankedEvidence(
    _ evidence: BankedResetEvidence, to data: [String: JSONValue]
) -> [String: JSONValue] {
    var augmented = data
    for (key, value) in evidence.data {
        augmented[key] = value
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let encoded = try? encoder.encode(augmented),
          encoded.count <= snapshotDataMaxAggregateBytes
    else { return data }
    return augmented
}

func makeProviderStatus(
    from entry: ProviderEntry,
    snapshotUpdatedAt: String,
    publishedAt: Date,
    syncSource: SyncSource? = nil,
    bankedObservation: BankedObservation? = nil
) throws -> ProviderStatus {
    if let error = entry.error, error.utf8.count > snapshotErrorMaxBytes {
        throw SnapshotDataValidationError.errorMessageTooLarge
    }
    var matchingBankedObservation: BankedObservation?
    if entry.name == "Codex",
       let observation = bankedObservation,
       let observedAt = entry.observedAt {
        if observation.matches(
            snapshotUpdatedAt: snapshotUpdatedAt,
            codexObservedAt: observedAt
        ) {
            matchingBankedObservation = observation
        }
    }
    return try ProviderStatus(
        providerName: entry.name,
        providerDisplayName: entry.name,
        ok: entry.ok,
        errorMessage: entry.error,
        windows: entry.windows,
        data: validatedAugmentedSnapshotData(
            entry.data,
            bankedObservation: matchingBankedObservation
        ),
        observedAt: entry.observedAt,
        snapshotUpdatedAt: snapshotUpdatedAt,
        publishedAt: publishedAt,
        syncSource: syncSource
    )
}
