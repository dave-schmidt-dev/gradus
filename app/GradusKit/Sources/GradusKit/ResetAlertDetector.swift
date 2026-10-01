import Foundation

/// An alert inferred from fresh source observations. The caller applies its
/// independent preferences before scheduling a local notification.
public enum ResetAlert: Equatable, Sendable {
    case bankedGrant(increase: Int, currentCount: Int)
    case usageRefill(providerName: String, windowID: String)
}

/// A valid count is current only for the observation being displayed. A prior
/// value is explicitly labeled as last observed when the current count is absent.
public enum ResetBankedStatus: Equatable, Sendable {
    case current(count: Int, observedAt: Date)
    case unavailable(lastObservedCount: Int?, lastObservedAt: Date?)
}

public struct ResetEvaluation: Equatable, Sendable {
    public let alerts: [ResetAlert]
    public let bankedStatus: ResetBankedStatus

    public init(alerts: [ResetAlert], bankedStatus: ResetBankedStatus) {
        self.alerts = alerts
        self.bankedStatus = bankedStatus
    }
}

/// A successful, fresh provider probe. A carried/failed entry must not be
/// marked fresh, even when its enclosing snapshot has a newer updated_at.
public struct ResetUsageObservation: Equatable, Sendable {
    public let providerName: String
    public let observedAt: Date
    public let windows: [ProviderWindow]
    public let isFresh: Bool

    public init(providerName: String, observedAt: Date, windows: [ProviderWindow], isFresh: Bool = true) {
        self.providerName = providerName
        self.observedAt = observedAt
        self.windows = windows
        self.isFresh = isFresh
    }

    public init?(entry: ProviderEntry, isFresh: Bool = true) {
        guard entry.ok, let raw = entry.observedAt,
              let observedAt = ResetAlertDetector.parseInstant(raw)
        else { return nil }
        self.init(providerName: entry.name, observedAt: observedAt, windows: entry.windows, isFresh: isFresh)
    }

    public init?(status: ProviderStatus, isFresh: Bool = true) {
        guard status.ok, let raw = status.observedAt,
              let observedAt = ResetAlertDetector.parseInstant(raw)
        else { return nil }
        self.init(providerName: status.providerName, observedAt: observedAt, windows: status.windows, isFresh: isFresh)
    }
}

/// Validated credential-free count evidence. Only native Codex may carry it.
public struct ResetBankedObservation: Equatable, Sendable {
    public let count: Int
    public let generation: String
    public let observedAt: Date

    public init?(count: Int, generation: String, observedAt: Date) {
        guard (0 ... 1_000_000).contains(count), UUID(uuidString: generation) != nil else { return nil }
        self.count = count
        self.generation = generation.lowercased()
        self.observedAt = observedAt
    }
}

/// Persist this state per app installation. A new/invalid installation has
/// silent baselines, never a synthetic historical grant or refill.
public struct ResetAlertState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    fileprivate var devices: [String: DeviceCursor]

    public init() {
        schemaVersion = Self.currentSchemaVersion
        devices = [:]
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, devices }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let version = try box.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw ResetAlertStateError.unsupportedSchemaVersion(version)
        }
        schemaVersion = version
        devices = try box.decodeIfPresent([String: DeviceCursor].self, forKey: .devices) ?? [:]
        guard devices.count <= 32 else { throw ResetAlertStateError.invalidState }
    }
}

public enum ResetAlertStateError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidState
}

private struct DeviceCursor: Codable, Equatable, Sendable {
    var usageObservedAt: [String: Date] = [:]
    var windows: [String: [String: WindowCursor]] = [:]
    var generations: [String: CountCursor] = [:]
    var latestCountGeneration: String?
    var touchedAt: Date = .distantPast

    private enum CodingKeys: String, CodingKey {
        case usageObservedAt, windows, generations, latestCountGeneration, touchedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        usageObservedAt = try box.decodeIfPresent([String: Date].self, forKey: .usageObservedAt) ?? [:]
        windows = try box.decodeIfPresent([String: [String: WindowCursor]].self, forKey: .windows) ?? [:]
        generations = try box.decodeIfPresent([String: CountCursor].self, forKey: .generations) ?? [:]
        latestCountGeneration = try box.decodeIfPresent(String.self, forKey: .latestCountGeneration)
        touchedAt = try box.decodeIfPresent(Date.self, forKey: .touchedAt) ?? .distantPast
        guard usageObservedAt.count <= 16, windows.count <= 16,
              windows.values.allSatisfy({ $0.count <= 16 }), generations.count <= 16
        else { throw ResetAlertStateError.invalidState }
    }
}

private struct WindowCursor: Codable, Equatable, Sendable {
    var percentLeft: Double
    var lastValidDeadline: Date?
    var nilDeadlineAlertedFor: Date?
    var armedLow: Bool
    var observedAt: Date

    private enum CodingKeys: String, CodingKey {
        case percentLeft, lastValidDeadline, nilDeadlineAlertedFor, armedLow, observedAt
    }

    init(
        percentLeft: Double, lastValidDeadline: Date?, nilDeadlineAlertedFor: Date?,
        armedLow: Bool, observedAt: Date
    ) {
        self.percentLeft = percentLeft
        self.lastValidDeadline = lastValidDeadline
        self.nilDeadlineAlertedFor = nilDeadlineAlertedFor
        self.armedLow = armedLow
        self.observedAt = observedAt
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        percentLeft = try box.decode(Double.self, forKey: .percentLeft)
        lastValidDeadline = try box.decodeIfPresent(Date.self, forKey: .lastValidDeadline)
        nilDeadlineAlertedFor = try box.decodeIfPresent(Date.self, forKey: .nilDeadlineAlertedFor)
        armedLow = try box.decode(Bool.self, forKey: .armedLow)
        observedAt = try box.decode(Date.self, forKey: .observedAt)
        guard percentIsValid(percentLeft) else { throw ResetAlertStateError.invalidState }
    }
}

private struct CountCursor: Codable, Equatable, Sendable {
    var count: Int
    var observedAt: Date
}

/// Pure refill and grant policy. The caller serializes state mutation and
/// persists the returned state before scheduling notifications.
public enum ResetAlertDetector {
    public static func parseInstant(_ raw: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: raw) {
            return date
        }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: raw)
    }

    public static func evaluate(
        state: inout ResetAlertState,
        deviceID: String,
        observation: ResetUsageObservation,
        banked: ResetBankedObservation? = nil
    ) -> ResetEvaluation {
        guard validDeviceID(deviceID) else {
            return ResetEvaluation(alerts: [], bankedStatus: .unavailable(lastObservedCount: nil, lastObservedAt: nil))
        }
        var device = state.devices[deviceID] ?? DeviceCursor()
        var alerts: [ResetAlert] = []

        if observation.isFresh, supportedProvider(observation.providerName),
           observation.observedAt > (device.usageObservedAt[observation.providerName] ?? .distantPast) {
            let refill = evaluateUsage(observation, device: &device)
            device.usageObservedAt[observation.providerName] = observation.observedAt
            if let refill {
                alerts.append(refill)
            }
            device.touchedAt = max(device.touchedAt, observation.observedAt)
        }

        // Banked evidence may be delivered after the usage observation was
        // evaluated. It has its own source timestamp and generation cursor.
        let countResult = evaluateCount(
            banked: observation.providerName == "Codex" && observation.isFresh &&
                banked?.observedAt == observation.observedAt ? banked : nil,
            device: &device
        )
        alerts.append(contentsOf: countResult.alerts)
        save(device, id: deviceID, state: &state)
        return ResetEvaluation(alerts: alerts, bankedStatus: countResult.bankedStatus)
    }

    /// Process a late matching sidecar without reconsidering the refill edge.
    public static func evaluateBankedCount(
        state: inout ResetAlertState,
        deviceID: String,
        banked: ResetBankedObservation?,
        displayedUsageObservedAt: Date? = nil
    ) -> ResetEvaluation {
        guard validDeviceID(deviceID) else {
            return ResetEvaluation(alerts: [], bankedStatus: .unavailable(lastObservedCount: nil, lastObservedAt: nil))
        }
        var device = state.devices[deviceID] ?? DeviceCursor()
        let result = evaluateCount(banked: banked, device: &device)
        save(device, id: deviceID, state: &state)
        if let displayedUsageObservedAt, displayedUsageObservedAt != banked?.observedAt {
            return ResetEvaluation(alerts: result.alerts, bankedStatus: unavailable(device))
        }
        return result
    }

    private static func evaluateUsage(_ observation: ResetUsageObservation, device: inout DeviceCursor) -> ResetAlert? {
        let provider = observation.providerName
        let prior = device.windows[provider] ?? [:]
        var next = prior
        var candidates: [String] = []
        var seen: Set<String> = []

        for window in observation.windows where seen.insert(window.id).inserted {
            guard validWindowID(window.id), percentIsValid(window.percentLeft) else {
                next.removeValue(forKey: window.id)
                continue
            }
            let deadline = window.resetISO.flatMap(parseInstant)
            let priorCursor = prior[window.id]
            if let priorCursor, observation.observedAt <= priorCursor.observedAt {
                continue
            }
            let crossed = priorCursor?.armedLow == true &&
                priorCursor!.percentLeft < 95 && window.percentLeft >= 95
            let qualifiesRefill = crossed && (window.resetISO == nil || deadline != nil) &&
                qualifies(provider: provider, priorDeadline: priorCursor?.lastValidDeadline,
                          newDeadline: deadline, nilDeadlineAlertedFor: priorCursor?.nilDeadlineAlertedFor,
                          at: observation.observedAt)
            if qualifiesRefill {
                candidates.append(window.id)
            }
            next[window.id] = WindowCursor(
                percentLeft: window.percentLeft,
                lastValidDeadline: deadline ?? priorCursor?.lastValidDeadline,
                nilDeadlineAlertedFor: qualifiesRefill && deadline == nil
                    ? priorCursor?.lastValidDeadline : priorCursor?.nilDeadlineAlertedFor,
                armedLow: window.percentLeft < 95,
                observedAt: observation.observedAt
            )
        }
        // A missing bucket is not evidence of recovery. Forget its low edge.
        for id in prior.keys where !seen.contains(id) {
            next.removeValue(forKey: id)
        }
        if next.count > 16 {
            let keep = Set(next.keys.sorted().prefix(16))
            next = next.filter { keep.contains($0.key) }
        }
        device.windows[provider] = next
        guard let selected = candidates.sorted(by: preferredWindow).first else { return nil }
        return .usageRefill(providerName: provider, windowID: selected)
    }

    private static func qualifies(
        provider: String, priorDeadline: Date?, newDeadline: Date?,
        nilDeadlineAlertedFor: Date?, at observedAt: Date
    ) -> Bool {
        guard let priorDeadline else { return false }
        if let newDeadline {
            if provider == "Codex" {
                return newDeadline >= priorDeadline
            }
            return observedAt >= priorDeadline && newDeadline > priorDeadline
        }
        // One fresh full observation after the old deadline can signal an
        // idle rollover when the source omits its new deadline.
        return observedAt >= priorDeadline && nilDeadlineAlertedFor != priorDeadline
    }

    private static func evaluateCount(banked: ResetBankedObservation?, device: inout DeviceCursor) -> ResetEvaluation {
        guard let banked else { return ResetEvaluation(alerts: [], bankedStatus: unavailable(device)) }
        let old = device.generations[banked.generation]
        if let old, banked.observedAt == old.observedAt, banked.count == old.count {
            return ResetEvaluation(alerts: [], bankedStatus: .current(count: old.count, observedAt: old.observedAt))
        }
        guard old == nil || banked.observedAt > old!.observedAt else {
            return ResetEvaluation(alerts: [], bankedStatus: unavailable(device))
        }
        var alerts: [ResetAlert] = []
        if let old, banked.count > old.count {
            alerts.append(.bankedGrant(increase: banked.count - old.count, currentCount: banked.count))
        }
        device.generations[banked.generation] = CountCursor(count: banked.count, observedAt: banked.observedAt)
        device.latestCountGeneration = banked.generation
        device.touchedAt = max(device.touchedAt, banked.observedAt)
        if device.generations.count > 16 {
            let excess = device.generations.count - 16
            let oldest = device.generations.sorted { $0.value.observedAt < $1.value.observedAt }
            for key in oldest.prefix(excess).map(\.key) {
                device.generations.removeValue(forKey: key)
            }
        }
        return ResetEvaluation(
            alerts: alerts,
            bankedStatus: .current(count: banked.count, observedAt: banked.observedAt)
        )
    }

    private static func unavailable(_ device: DeviceCursor) -> ResetBankedStatus {
        guard let generation = device.latestCountGeneration,
              let last = device.generations[generation]
        else { return .unavailable(lastObservedCount: nil, lastObservedAt: nil) }
        return .unavailable(lastObservedCount: last.count, lastObservedAt: last.observedAt)
    }

    private static func save(_ device: DeviceCursor, id: String, state: inout ResetAlertState) {
        state.devices[id] = device
        if state.devices.count > 32 {
            let excess = state.devices.count - 32
            for key in state.devices.sorted(by: { $0.value.touchedAt < $1.value.touchedAt }).prefix(excess).map(\.key) {
                state.devices.removeValue(forKey: key)
            }
        }
    }

    private static func supportedProvider(_ name: String) -> Bool {
        name == "Codex" || name == "Claude"
    }

    private static func validDeviceID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128
    }

    private static func validWindowID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64
    }

    /// True for the one-week window (`weekly`); every other window the
    /// detector reports on (`five_hour`) is a short window.
    public static func isWeeklyWindow(_ id: String) -> Bool {
        id.lowercased().contains("week")
    }

    private static func preferredWindow(_ lhs: String, _ rhs: String) -> Bool {
        let lhsWeekly = isWeeklyWindow(lhs)
        let rhsWeekly = isWeeklyWindow(rhs)
        return lhsWeekly == rhsWeekly ? lhs < rhs : lhsWeekly
    }
}
