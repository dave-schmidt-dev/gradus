import Foundation

/// The only schema version this client accepts (CR-12 / INV-5). Any other
/// value is refused, not silently decoded.
public let supportedSchemaVersion = 2

public enum SnapshotDecodeError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}

public struct ProviderWindow: Codable, Equatable, Sendable {
    public let id: String
    public let percentLeft: Double
    public let resetISO: String?
    public let windowHours: Double?
    public let paceDelta: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case percentLeft = "percent_left"
        case resetISO = "reset_iso"
        case windowHours = "window_hours"
        case paceDelta = "pace_delta"
    }

    public init(
        id: String,
        percentLeft: Double,
        resetISO: String?,
        windowHours: Double?,
        paceDelta: Double?
    ) {
        self.id = id
        self.percentLeft = percentLeft
        self.resetISO = resetISO
        self.windowHours = windowHours
        self.paceDelta = paceDelta
    }
}

public struct ProviderEntry: Codable, Equatable, Sendable {
    public let name: String
    public let ok: Bool
    public let error: String?
    public let windows: [ProviderWindow]
    public let data: [String: JSONValue]
    public let observedAt: String?

    enum CodingKeys: String, CodingKey {
        case name, ok, error, windows, data
        case observedAt = "observed_at"
    }

    public init(
        name: String,
        ok: Bool,
        error: String?,
        windows: [ProviderWindow],
        data: [String: JSONValue],
        observedAt: String?
    ) {
        self.name = name
        self.ok = ok
        self.error = error
        self.windows = windows
        self.data = data
        self.observedAt = observedAt
    }
}

/// Mirrors the Python `build_snapshot_v2_payload` output (`gradus/snapshot.py`).
/// Unknown/additive top-level or per-provider fields are silently ignored
/// (forward-compat, INV-5) — only `schema_version` is strictly enforced.
public struct SnapshotPayload: Equatable, Sendable {
    public let schemaVersion: Int
    public let updatedAt: String
    public let providers: [ProviderEntry]

    public init(schemaVersion: Int, updatedAt: String, providers: [ProviderEntry]) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.providers = providers
    }
}

extension SnapshotPayload: Decodable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case updatedAt = "updated_at"
        case providers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == supportedSchemaVersion else {
            throw SnapshotDecodeError.unsupportedSchemaVersion(version)
        }
        schemaVersion = version
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        providers = try container.decode([ProviderEntry].self, forKey: .providers)
    }
}

extension SnapshotPayload: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(providers, forKey: .providers)
    }
}
