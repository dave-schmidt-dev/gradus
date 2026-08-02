import CloudKit
import Foundation

/// Fixed identifiers shared by both apps (§6.1 of the plan) — same team,
/// same container, one custom zone (change tokens need a non-default zone).
public enum CloudKitConstants {
    public static let containerIdentifier = "iCloud.com.zerodelta.gradus"
    public static let zoneName = "GradusZone"
    public static let recordType = "ProviderStatus"
}

/// One record per provider (§5.1) — `sourceDevice` deliberately omitted
/// (CR-10/INV-1: no device-identifying value enters CloudKit).
public struct ProviderStatus: Equatable, Sendable {
    public let providerName: String
    public let providerDisplayName: String
    public let ok: Bool
    public let errorMessage: String?
    public let windows: [ProviderWindow]
    public let data: [String: JSONValue]
    public let observedAt: String?
    public let snapshotUpdatedAt: String
    public let publishedAt: Date
    public let isWarning: Bool
    public let isDepleted: Bool

    public init(
        providerName: String,
        providerDisplayName: String,
        ok: Bool,
        errorMessage: String?,
        windows: [ProviderWindow],
        data: [String: JSONValue],
        observedAt: String?,
        snapshotUpdatedAt: String,
        publishedAt: Date,
        isWarning: Bool? = nil,
        isDepleted: Bool? = nil
    ) {
        self.providerName = providerName
        self.providerDisplayName = providerDisplayName
        self.ok = ok
        self.errorMessage = errorMessage
        self.windows = windows
        self.data = data
        self.observedAt = observedAt
        self.snapshotUpdatedAt = snapshotUpdatedAt
        self.publishedAt = publishedAt
        self.isWarning = isWarning ?? windows.contains(where: windowWarns)
        self.isDepleted = isDepleted ?? windows.contains { percentIsDepleted($0.percentLeft) }
    }
}

public enum ProviderStatusMappingError: Error, Equatable {
    case missingField(String)
}

extension ProviderStatus {
    /// Encode to a `CKRecord` in `GradusZone`. `windowsJSON`/`dataJSON` are
    /// JSON-encoded blob fields (§5.1) rather than nested CKRecord structure.
    public func toCKRecord(zoneID: CKRecordZone.ID) throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: providerName, zoneID: zoneID)
        let record = CKRecord(recordType: CloudKitConstants.recordType, recordID: recordID)
        record["providerName"] = providerName as CKRecordValue
        record["providerDisplayName"] = providerDisplayName as CKRecordValue
        record["ok"] = NSNumber(value: ok)
        record["errorMessage"] = errorMessage as CKRecordValue?
        record["windowsJSON"] = try jsonString(for: windows) as CKRecordValue
        record["dataJSON"] = try jsonString(for: data) as CKRecordValue
        record["observedAt"] = observedAt as CKRecordValue?
        record["snapshotUpdatedAt"] = snapshotUpdatedAt as CKRecordValue
        record["publishedAt"] = publishedAt as CKRecordValue
        record["isWarning"] = NSNumber(value: isWarning)
        record["isDepleted"] = NSNumber(value: isDepleted)
        return record
    }

    /// Decode from a `CKRecord`. Malformed or missing `windowsJSON`/`dataJSON`
    /// degrade to an empty collection rather than throwing (CV-3) — mirroring
    /// the Python side's per-window isolation (a malformed field must never
    /// hide an otherwise-valid record). Only truly required identity fields
    /// (`providerName`, `ok`, `snapshotUpdatedAt`, `publishedAt`) throw.
    public init(record: CKRecord) throws {
        guard let providerName = record["providerName"] as? String else {
            throw ProviderStatusMappingError.missingField("providerName")
        }
        guard let okNumber = record["ok"] as? NSNumber else {
            throw ProviderStatusMappingError.missingField("ok")
        }
        guard let snapshotUpdatedAt = record["snapshotUpdatedAt"] as? String else {
            throw ProviderStatusMappingError.missingField("snapshotUpdatedAt")
        }
        guard let publishedAt = record["publishedAt"] as? Date else {
            throw ProviderStatusMappingError.missingField("publishedAt")
        }

        self.providerName = providerName
        self.providerDisplayName = (record["providerDisplayName"] as? String) ?? providerName
        self.ok = okNumber.boolValue
        self.errorMessage = record["errorMessage"] as? String
        self.windows = Self.decodeWindows(from: record["windowsJSON"] as? String)
        self.data = Self.decodeData(from: record["dataJSON"] as? String)
        self.observedAt = record["observedAt"] as? String
        self.snapshotUpdatedAt = snapshotUpdatedAt
        self.publishedAt = publishedAt
        self.isWarning = (record["isWarning"] as? NSNumber)?.boolValue
            ?? windows.contains(where: windowWarns)
        self.isDepleted = (record["isDepleted"] as? NSNumber)?.boolValue
            ?? windows.contains { percentIsDepleted($0.percentLeft) }
    }

    private static func decodeWindows(from json: String?) -> [ProviderWindow] {
        guard let json, let data = json.data(using: .utf8),
            let windows = try? JSONDecoder().decode([ProviderWindow].self, from: data)
        else {
            return []
        }
        return windows
    }

    private static func decodeData(from json: String?) -> [String: JSONValue] {
        guard let json, let data = json.data(using: .utf8),
            let value = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else {
            return [:]
        }
        return value
    }

    private func jsonString(for windows: [ProviderWindow]) throws -> String {
        let data = try JSONEncoder().encode(windows)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func jsonString(for data: [String: JSONValue]) throws -> String {
        let encoded = try JSONEncoder().encode(data)
        return String(data: encoded, encoding: .utf8) ?? "{}"
    }
}

/// Write side of the CloudKit seam (Phase 2 Mac publisher implements this).
public protocol CloudPublisher: Sendable {
    func upsert(_ statuses: [ProviderStatus]) async throws
}

/// Read side of the CloudKit seam (Phase 3 iOS consumer implements this).
public protocol CloudFetcher: Sendable {
    func fetchAll() async throws -> [ProviderStatus]
}

/// Push-alert seam (§6.4) — a `CKQuerySubscription` on `isWarning == 1`.
public protocol CloudSubscriber: Sendable {
    func subscribeToWarnings() async throws
}
