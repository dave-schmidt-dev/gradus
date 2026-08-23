import Foundation

/// The schema version for the widget snapshot contract (INV-5, INV-14).
public let supportedWidgetSnapshotSchemaVersion = 1

public enum WidgetSnapshotDecodeError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

/// The coarse-grained operational statuses a small widget presents.
public enum WidgetProviderStatus: String, Codable, Equatable, Sendable {
    case ok
    case warning
    case attention
    case depleted
    case error
}

/// Human-readable label normalization for standard quota window identifiers.
public func normalizedWidgetWindowLabel(for id: String) -> String {
    let labels = [
        "five_hour": "5 Hour",
        "weekly": "Weekly",
        "monthly": "Monthly",
        "premium": "Monthly",
        "ac": "Auto",
        "ap": "API",
        "cg5": "5 Hour (CG)",
        "cg1w": "Weekly (CG)",
        "cg_five_hour": "5 Hour (CG)",
        "cg_weekly": "Weekly (CG)",
        "billing_cycle": "Monthly"
    ]
    return labels[id] ?? id
}

private func widgetSignalLevel(for window: ProviderWindow) -> SignalLevel {
    signalLevel(for: window)
}

/// Selected quota window projection for small widget presentation.
///
/// Contains only presentation-ready values: stable identifier, normalized
/// display label, normalized remaining percentage, computed signal level, and
/// optional reset date. Carries no credentials, paths, or unparsed payloads.
public struct WidgetWindowSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let percentLeft: Double
    public let signalLevel: SignalLevel
    public let resetDate: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case percentLeft = "percent_left"
        case signalLevel = "signal_level"
        case resetDate = "reset_date"
    }

    public init(
        id: String,
        label: String,
        percentLeft: Double,
        signalLevel: SignalLevel,
        resetDate: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.percentLeft = percentLeft
        self.signalLevel = signalLevel
        self.resetDate = resetDate
    }

    public init(from window: ProviderWindow, label: String? = nil) {
        id = window.id
        self.label = label ?? normalizedWidgetWindowLabel(for: window.id)
        percentLeft = window.percentLeft
        signalLevel = widgetSignalLevel(for: window)
        resetDate = window.resetISO.flatMap(parseWidgetISO8601Date)
    }
}

private func parseWidgetISO8601Date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

/// Rank signal severity from highest (red = 4) to lowest (unknown = 0).
private func signalSeverityRank(_ level: SignalLevel) -> Int {
    switch level {
    case .red: 4
    case .orange: 3
    case .yellow: 2
    case .green: 1
    case .unknown: 0
    }
}

/// Deterministic comparison order for widget window candidates:
/// 1. Highest signal severity first (red > orange > yellow > green > unknown)
/// 2. Lowest percentLeft first
/// 3. Ascending stable window ID
public func compareWidgetWindows(_ lhs: ProviderWindow, _ rhs: ProviderWindow) -> Bool {
    let lhsSeverity = signalSeverityRank(signalLevel(for: lhs))
    let rhsSeverity = signalSeverityRank(signalLevel(for: rhs))
    if lhsSeverity != rhsSeverity {
        return lhsSeverity > rhsSeverity
    }
    if lhs.percentLeft != rhs.percentLeft {
        return lhs.percentLeft < rhs.percentLeft
    }
    return lhs.id < rhs.id
}

/// Deterministic valid-window selector for widget presentation.
/// Invalid percentages are excluded and an empty candidate set returns nil.
public func selectWidgetWindow(from windows: [ProviderWindow]) -> ProviderWindow? {
    let validWindows = windows.filter { percentIsValid($0.percentLeft) }
    guard !validWindows.isEmpty else { return nil }
    return validWindows.sorted(by: compareWidgetWindows).first
}

/// Projects the deterministically selected valid window into a `WidgetWindowSnapshot`.
public func selectWidgetWindowSnapshot(from windows: [ProviderWindow]) -> WidgetWindowSnapshot? {
    guard let selected = selectWidgetWindow(from: windows) else { return nil }
    return WidgetWindowSnapshot(from: selected)
}

/// Schema-v1 widget snapshot containing only safe presentation fields (INV-14).
///
/// Strictly excludes ProviderStatus.data, errorMessage, identity, CloudKit/account/token
/// data, credentials, and filesystem paths. Unknown schema versions are rejected
/// on decoding.
public struct WidgetSnapshot: Equatable, Sendable {
    public typealias Status = WidgetProviderStatus
    public typealias SelectedWindow = WidgetWindowSnapshot

    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let phoneSyncDate: Date
    public let providerName: String
    public let providerDisplayName: String
    public let status: WidgetProviderStatus
    public let selectedWindow: WidgetWindowSnapshot?

    public init(
        schemaVersion: Int = WidgetSnapshot.currentSchemaVersion,
        phoneSyncDate: Date,
        providerName: String,
        providerDisplayName: String,
        status: WidgetProviderStatus,
        selectedWindow: WidgetWindowSnapshot? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.phoneSyncDate = phoneSyncDate
        self.providerName = providerName
        self.providerDisplayName = providerDisplayName
        self.status = status
        self.selectedWindow = selectedWindow
    }
}

extension WidgetSnapshot: Codable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case phoneSyncDate = "phone_sync_date"
        case providerName = "provider_name"
        case providerDisplayName = "provider_display_name"
        case status
        case selectedWindow = "selected_window"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == supportedWidgetSnapshotSchemaVersion else {
            throw WidgetSnapshotDecodeError.unsupportedSchemaVersion(version)
        }
        schemaVersion = version
        phoneSyncDate = try container.decode(Date.self, forKey: .phoneSyncDate)
        providerName = try container.decode(String.self, forKey: .providerName)
        providerDisplayName = try container.decode(String.self, forKey: .providerDisplayName)
        status = try container.decode(WidgetProviderStatus.self, forKey: .status)
        selectedWindow = try container.decodeIfPresent(WidgetWindowSnapshot.self, forKey: .selectedWindow)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(phoneSyncDate, forKey: .phoneSyncDate)
        try container.encode(providerName, forKey: .providerName)
        try container.encode(providerDisplayName, forKey: .providerDisplayName)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(selectedWindow, forKey: .selectedWindow)
    }
}
