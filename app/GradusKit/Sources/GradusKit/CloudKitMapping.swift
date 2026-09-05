import CloudKit
import Foundation

/// Fixed identifiers shared by both apps (§6.1 of the plan) — same team,
/// same container, one custom zone (change tokens need a non-default zone).
public enum CloudKitConstants {
    public static let containerIdentifier = "iCloud.com.zerodelta.gradus"
    public static let zoneName = "GradusZone"
    public static let recordType = "ProviderStatus"
    public static let devicePresenceRecordType = "DevicePresence"
    public static let devicePresenceSubscriptionID = "gradus-device-presence"
}

/// The only user-visible values a live mobile installation may publish.
public enum DevicePresenceName: String, Codable, CaseIterable, Sendable {
    case iPhone
    case iPad
}

/// A short-lived foreground lease for one mobile installation. The installation
/// identifier is deliberately represented only by the CloudKit record key; it
/// is never copied into a record field, UI, log, or receipt.
public struct DevicePresence: Codable, Equatable, Sendable, Identifiable {
    public let installationID: String
    public let displayName: DevicePresenceName
    public let expiresAt: Date

    public var id: String {
        installationID
    }

    public init(installationID: String, displayName: DevicePresenceName, expiresAt: Date) {
        self.installationID = installationID
        self.displayName = displayName
        self.expiresAt = expiresAt
    }

    public var isActive: Bool {
        isActive(at: Date())
    }

    public func isActive(at date: Date) -> Bool {
        expiresAt > date
    }

    /// The approved ten-minute lease. Callers renew before this deadline.
    public static let leaseDuration: TimeInterval = 10 * 60
    public static let renewalInterval: TimeInterval = 5 * 60

    public func toCKRecord(zoneID: CKRecordZone.ID) throws -> CKRecord {
        guard Self.isOpaqueInstallationID(installationID) else {
            throw DevicePresenceMappingError.invalidInstallationID
        }
        let record = CKRecord(
            recordType: CloudKitConstants.devicePresenceRecordType,
            recordID: CKRecord.ID(recordName: installationID, zoneID: zoneID)
        )
        record["displayName"] = displayName.rawValue as CKRecordValue
        record["expiresAt"] = expiresAt as CKRecordValue
        return record
    }

    public init(record: CKRecord) throws {
        guard record.recordType == CloudKitConstants.devicePresenceRecordType else {
            throw DevicePresenceMappingError.wrongRecordType
        }
        let installationID = record.recordID.recordName
        guard Self.isOpaqueInstallationID(installationID) else {
            throw DevicePresenceMappingError.invalidInstallationID
        }
        guard let rawName = record["displayName"] as? String,
              let displayName = DevicePresenceName(rawValue: rawName)
        else {
            throw DevicePresenceMappingError.missingField("displayName")
        }
        guard let expiresAt = record["expiresAt"] as? Date else {
            throw DevicePresenceMappingError.missingField("expiresAt")
        }
        self.init(installationID: installationID, displayName: displayName, expiresAt: expiresAt)
    }

    private static func isOpaqueInstallationID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }
}

public enum DevicePresenceMappingError: Error, Equatable {
    case invalidInstallationID
    case wrongRecordType
    case missingField(String)
}

public enum DevicePresenceDeletionRoute: Equatable, Sendable {
    case provider(String)
    case presence(String)
}

/// CloudKit deletion callbacks include the record type. Unknown types are
/// ignored so a future record family cannot affect provider or presence state.
public enum DevicePresenceDeletionRouter {
    public static func route(recordName: String, recordType: String) -> DevicePresenceDeletionRoute? {
        switch recordType {
        case CloudKitConstants.devicePresenceRecordType: .presence(recordName)
        case CloudKitConstants.recordType: .provider(recordName)
        default: nil
        }
    }
}

/// Deterministic consumer policy. Duplicate generic names are retained: two
/// phones may be active at once, and collapsing them would hide a real device.
public enum DevicePresenceDirectory {
    public static func active(_ records: [DevicePresence], at date: Date) -> [DevicePresence] {
        records
            .filter { $0.isActive(at: date) }
            .sorted {
                if $0.displayName != $1.displayName {
                    return $0.displayName.rawValue < $1.displayName.rawValue
                }
                if $0.expiresAt != $1.expiresAt {
                    return $0.expiresAt < $1.expiresAt
                }
                return $0.installationID < $1.installationID
            }
    }

    public static func expired(_ records: [DevicePresence], at date: Date) -> [DevicePresence] {
        records.filter { !$0.isActive(at: date) }
    }
}

/// App-container persistence for the opaque per-install identifier. This is
/// UserDefaults-backed by design: it stays in the app container and is not a
/// Keychain or IDFV identity. A fresh app install gets a new random UUID.
public struct DevicePresenceInstallationStore {
    public static let key = "devicePresenceInstallationID"
    private let defaults: UserDefaults
    private let makeID: @Sendable () -> String

    public init(defaults: UserDefaults = .standard, makeID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.defaults = defaults
        self.makeID = makeID
    }

    public func installationID() -> String {
        if let existing = defaults.string(forKey: Self.key), UUID(uuidString: existing) != nil {
            return existing
        }
        let fresh = makeID()
        guard UUID(uuidString: fresh) != nil else {
            let fallback = UUID().uuidString
            defaults.set(fallback, forKey: Self.key)
            return fallback
        }
        defaults.set(fresh, forKey: Self.key)
        return fresh
    }
}

/// CloudKit-independent seam used by both mobile writers and the Mac
/// directory. Implementations must route only `DevicePresence` records.
public protocol DevicePresenceClient: Sendable {
    func upsert(_ presence: DevicePresence) async throws
    func delete(installationID: String) async throws
    func fetchAll() async throws -> [DevicePresence]
    func subscribe() async throws
}

/// Small policy object shared by iPhone and iPad lifecycle code. It never
/// writes in sample mode, migration recovery, or a denied account state.
public struct DevicePresenceLease: Sendable {
    public let installationID: String
    public let displayName: DevicePresenceName
    public let duration: TimeInterval

    public init(
        installationID: String,
        displayName: DevicePresenceName,
        duration: TimeInterval = DevicePresence.leaseDuration
    ) {
        self.installationID = installationID
        self.displayName = displayName
        self.duration = duration
    }

    public func presence(now: Date) -> DevicePresence {
        DevicePresence(
            installationID: installationID, displayName: displayName,
            expiresAt: now.addingTimeInterval(duration)
        )
    }
}

/// One record per provider (§5.1). Optional source metadata identifies the
/// local Mac that published the record so the iOS dashboard can show which
/// computer it is connected to. It is deliberately limited to a display
/// name and short local username; no account email, serial, path, or secret
/// enters CloudKit. Older records decode with `syncSource == nil`.
public struct ProviderStatus: Codable, Equatable, Sendable {
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
    public let syncSource: SyncSource?

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
        isDepleted: Bool? = nil,
        syncSource: SyncSource? = nil
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
        self.isWarning = isWarning ?? providerNeedsAttention(windows)
        self.isDepleted = isDepleted ?? providerIsDepleted(providerName: providerName, windows: windows)
        self.syncSource = syncSource
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
        record["sourceComputerName"] = syncSource?.computerName as CKRecordValue?
        record["sourceUserName"] = syncSource?.userName as CKRecordValue?
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
        providerDisplayName = (record["providerDisplayName"] as? String) ?? providerName
        ok = okNumber.boolValue
        errorMessage = record["errorMessage"] as? String
        windows = Self.decodeWindows(from: record["windowsJSON"] as? String)
        data = Self.decodeData(from: record["dataJSON"] as? String)
        observedAt = record["observedAt"] as? String
        self.snapshotUpdatedAt = snapshotUpdatedAt
        self.publishedAt = publishedAt
        isWarning = (record["isWarning"] as? NSNumber)?.boolValue
            ?? windows.contains(where: windowWarns)
        isDepleted = (record["isDepleted"] as? NSNumber)?.boolValue
            ?? providerIsDepleted(providerName: providerName, windows: windows)
        if let computerName = record["sourceComputerName"] as? String,
           let userName = record["sourceUserName"] as? String,
           !computerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            syncSource = SyncSource(computerName: computerName, userName: userName)
        } else {
            syncSource = nil
        }
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
