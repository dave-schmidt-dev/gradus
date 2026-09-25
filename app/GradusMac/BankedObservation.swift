import CoreFoundation
import Foundation

private struct BankedObservationWriterShape: Decodable {
    let schemaVersion: Int
    let count: Int
    let generation: String
    let snapshotUpdatedAt: String
    let observedAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case count, generation
        case snapshotUpdatedAt = "snapshot_updated_at"
        case observedAt = "observed_at"
    }
}

/// The credential-free companion to a committed v2 snapshot. A count is only
/// current when its snapshot token and Codex observation match that snapshot.
public struct BankedObservation: Equatable, Sendable {
    public static let filename = "banked-observation-v1.json"
    public static let maximumCount = 1_000_000
    public static let maximumObservationLag: TimeInterval = 15 * 60
    public static let maximumFileSize = 4096

    public let count: Int
    public let generation: String
    public let snapshotUpdatedAt: String
    public let observedAt: String
    public let snapshotDate: Date
    public let observedDate: Date

    /// Derive only from the injected public snapshot URL. No private cache or
    /// source-tree mirror is consulted by the Mac reader.
    public static func fileURL(for snapshotFileURL: URL) -> URL {
        snapshotFileURL.deletingLastPathComponent().appendingPathComponent(filename)
    }

    /// Reject partial, oversized, or altered writer data before any field is
    /// used for display, alert classification, or CloudKit augmentation.
    public static func parse(_ data: Data) -> BankedObservation? {
        guard !data.isEmpty, data.count <= maximumFileSize,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set([
                  "schema_version", "count", "generation", "snapshot_updated_at", "observed_at"
              ]),
              integer(object["schema_version"]) == 1,
              let rawCount = integer(object["count"]),
              (0 ... maximumCount).contains(rawCount),
              let shape = try? JSONDecoder().decode(BankedObservationWriterShape.self, from: data),
              shape.schemaVersion == 1,
              (0 ... maximumCount).contains(shape.count),
              let generation = UUID(uuidString: shape.generation),
              generation.uuidString.lowercased() == shape.generation,
              let snapshotDate = timestamp(shape.snapshotUpdatedAt),
              let observedDate = timestamp(shape.observedAt),
              observedDate <= snapshotDate,
              snapshotDate.timeIntervalSince(observedDate) <= maximumObservationLag
        else { return nil }

        return BankedObservation(
            count: shape.count,
            generation: generation.uuidString.lowercased(),
            snapshotUpdatedAt: shape.snapshotUpdatedAt,
            observedAt: shape.observedAt,
            snapshotDate: snapshotDate,
            observedDate: observedDate
        )
    }

    public static func read(from fileURL: URL) -> BankedObservation? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        return parse(data)
    }

    /// A retained sidecar can be shown as "Last observed", but it must not
    /// become a fresh alert input until both public-source tokens agree.
    public func matches(snapshotUpdatedAt: String, codexObservedAt: String) -> Bool {
        self.snapshotUpdatedAt == snapshotUpdatedAt && observedAt == codexObservedAt
    }

    private static func timestamp(_ value: String) -> Date? {
        // ISO8601DateFormatter alone accepts normalized variants. Require the
        // Python writer's offset-aware, second-resolution form first.
        let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"#
            + #"(?:\.[0-9]{1,6})?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#
        guard value.range(of: pattern, options: .regularExpression) != nil,
              let year = Int(value.prefix(4)), year > 0,
              let month = Int(value.dropFirst(5).prefix(2)), (1 ... 12).contains(month),
              let day = Int(value.dropFirst(8).prefix(2)),
              let hour = Int(value.dropFirst(11).prefix(2)), (0 ... 23).contains(hour),
              let minute = Int(value.dropFirst(14).prefix(2)), (0 ... 59).contains(minute),
              let second = Int(value.dropFirst(17).prefix(2)), (0 ... 59).contains(second)
        else { return nil }
        let leapYear = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1 ... daysInMonth[month - 1]).contains(day) else { return nil }
        if !value.hasSuffix("Z") {
            let offset = value.suffix(6)
            guard let offsetHour = Int(offset.dropFirst().prefix(2)), (0 ... 23).contains(offsetHour),
                  let offsetMinute = Int(offset.suffix(2)), (0 ... 59).contains(offsetMinute)
            else { return nil }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType))
        else { return nil }
        return number.intValue
    }
}
