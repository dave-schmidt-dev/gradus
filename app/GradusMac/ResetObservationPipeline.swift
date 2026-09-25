import Foundation
import GradusKit

/// Joins three public, atomic files on the main actor. File events are hints:
/// every decision rereads the current files, so event delivery order cannot
/// authorize an older or rolled-back observation.
@MainActor
final class ResetObservationPipeline {
    enum ProducerMode { case installed, external }

    private let snapshotURL: URL
    private let statusURL: URL
    private let sidecarURL: URL
    private let mode: ProducerMode
    private let defaults: UserDefaults
    private let deviceID: String
    private let waitInterval: TimeInterval
    private let now: () -> Date
    private let onDisplay: (SnapshotPayload) -> Void
    private let onEvaluation: (ResetEvaluation) -> Void
    private let onCommit: (SnapshotPayload, BankedObservation?) -> Void
    private let onProgress: (String?) -> Void
    private let onStatusChange: () -> Void

    private var snapshotWatcher: SnapshotWatcher?
    private var sidecarWatcher: BankedObservationWatcher?
    private var statusObserver: BackgroundAgentStatusObserver?
    private var pending: SnapshotPayload?
    private var committed: [String: SnapshotPayload] = [:]
    private var committedOrder: [String] = []
    private var processedSidecars: Set<String> = []
    private var latestDisplayed: SnapshotPayload?
    private var waitStartedAt: Date?
    private var waitSerial: UInt64 = 0
    private var state: ResetAlertState

    private static let stateKey = "resetAlertDetectorStateV1"

    init(
        snapshotURL: URL,
        mode: ProducerMode,
        defaults: UserDefaults = .standard,
        deviceID: String? = nil,
        waitInterval: TimeInterval = 15,
        now: @escaping () -> Date = Date.init,
        onDisplay: @escaping (SnapshotPayload) -> Void,
        onEvaluation: @escaping (ResetEvaluation) -> Void,
        onCommit: @escaping (SnapshotPayload, BankedObservation?) -> Void,
        onProgress: @escaping (String?) -> Void = { _ in },
        onStatusChange: @escaping () -> Void = {}
    ) {
        self.snapshotURL = snapshotURL
        statusURL = BackgroundAgentStatusObserver.statusFileURL(for: snapshotURL)
        sidecarURL = BankedObservation.fileURL(for: snapshotURL)
        self.mode = mode
        self.defaults = defaults
        self.deviceID = deviceID ?? DevicePresenceInstallationStore(defaults: defaults).installationID()
        self.waitInterval = waitInterval
        self.now = now
        self.onDisplay = onDisplay
        self.onEvaluation = onEvaluation
        self.onCommit = onCommit
        self.onProgress = onProgress
        self.onStatusChange = onStatusChange
        state = (defaults.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(ResetAlertState.self, from: $0) }) ?? ResetAlertState()
    }

    func start() {
        guard snapshotWatcher == nil else { return }
        let watcher = SnapshotWatcher(path: snapshotURL) { [weak self] _ in
            Task { @MainActor [weak self] in self?.snapshotChanged() }
        }
        snapshotWatcher = watcher
        let sidecarWatcher = BankedObservationWatcher(snapshotFileURL: snapshotURL) { [weak self] in
            self?.sidecarChanged()
        }
        self.sidecarWatcher = sidecarWatcher
        let statusObserver = BackgroundAgentStatusObserver(snapshotFileURL: snapshotURL) { [weak self] in
            self?.statusChanged()
        }
        self.statusObserver = statusObserver
        // These watches start regardless of required-iCloud confirmation.
        sidecarWatcher.start()
        statusObserver.start()
        Task { await watcher.start() }
    }

    func stop() {
        sidecarWatcher?.stop()
        statusObserver?.stop()
        sidecarWatcher = nil
        statusObserver = nil
        let watcher = snapshotWatcher
        snapshotWatcher = nil
        Task { await watcher?.stop() }
        pending = nil
        cancelWait()
    }

    /// Called by the watcher and tests. The current v2 file, never the event's
    /// possibly superseded payload, is the authority for the join.
    func snapshotChanged() {
        guard let payload = readSnapshot() else { return }
        receive(payload)
    }

    func statusChanged() {
        onStatusChange()
        if let pending {
            reconcile(pending)
        } else if isFailure(readStatus()?.phase) {
            rereadRollback()
        }
    }

    func sidecarChanged() {
        guard let sidecar = BankedObservation.read(from: sidecarURL) else { return }
        if let pending, matches(sidecar, payload: pending) {
            reconcile(pending)
            return
        }
        guard let oldPayload = committed[sidecar.snapshotUpdatedAt],
              matches(sidecar, payload: oldPayload)
        else { return }
        acceptLateCount(sidecar, payload: oldPayload)
    }

    /// Confirmation can occur after a local observation was committed. Replay
    /// its publication without running the detector or rescheduling an alert.
    func publishCurrentIfCommitted() {
        guard let token = committedOrder.last,
              let payload = committed[token],
              readSnapshot()?.updatedAt == token
        else { return }
        let sidecar = BankedObservation.read(from: sidecarURL).flatMap {
            matches($0, payload: payload) ? $0 : nil
        }
        onCommit(payload, sidecar)
    }

    /// Deterministic timeout seam; the real timer calls this once a second.
    func checkTimeout() {
        guard let pending, let waitStartedAt else { return }
        let remaining = waitInterval - now().timeIntervalSince(waitStartedAt)
        if remaining <= 0 {
            onProgress(nil)
            self.waitStartedAt = nil
            commit(pending, banked: nil)
        } else {
            onProgress("Waiting for reset count (up to \(Int(ceil(remaining))) seconds)…")
        }
    }

    private func receive(_ payload: SnapshotPayload) {
        if let latestDisplayed,
           let newDate = ResetAlertDetector.parseInstant(payload.updatedAt),
           let oldDate = ResetAlertDetector.parseInstant(latestDisplayed.updatedAt),
           newDate < oldDate {
            return
        }
        if latestDisplayed != payload {
            latestDisplayed = payload
            onDisplay(payload)
        }
        guard committed[payload.updatedAt] == nil else {
            if let sidecar = BankedObservation.read(from: sidecarURL), matches(sidecar, payload: payload) {
                acceptLateCount(sidecar, payload: payload)
            }
            return
        }
        if pending?.updatedAt != payload.updatedAt {
            cancelWait()
        }
        pending = payload
        reconcile(payload)
    }

    private func reconcile(_ candidate: SnapshotPayload) {
        guard pending?.updatedAt == candidate.updatedAt else { return }
        // Recheck the public file after status/sidecar notification, including
        // the gap between a writer's v2 and history/status commits.
        guard let current = readSnapshot() else { return }
        if current.updatedAt != candidate.updatedAt {
            receive(current)
            return
        }
        let status = readStatus()
        if mode == .installed, isFailure(status?.phase) {
            pending = nil
            cancelWait()
            rereadRollback()
            return
        }
        if mode == .installed, status?.phase == .restoringSnapshot {
            pending = nil
            cancelWait()
            rereadRollback()
            return
        }
        if status?.phase == .succeeded,
           status?.committedSnapshotUpdatedAt == candidate.updatedAt {
            cancelWait()
            let sidecar = BankedObservation.read(from: sidecarURL).flatMap {
                matches($0, payload: candidate) ? $0 : nil
            }
            commit(candidate, banked: sidecar)
            return
        }
        if mode == .installed {
            return
        }
        // A live installed run must reach its own terminal status. External
        // writers without one get a bounded wait for a matching sidecar.
        if status?.isInFlight == true {
            return
        }
        if let sidecar = BankedObservation.read(from: sidecarURL),
           matches(sidecar, payload: candidate) {
            cancelWait()
            commit(candidate, banked: sidecar)
            return
        }
        startWaitIfNeeded()
    }

    private func startWaitIfNeeded() {
        guard waitStartedAt == nil else { return }
        waitStartedAt = now()
        waitSerial &+= 1
        let serial = waitSerial
        onProgress("Waiting for reset count (up to \(Int(ceil(waitInterval))) seconds)…")
        scheduleTick(serial: serial)
    }

    private func scheduleTick(serial: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, waitSerial == serial, waitStartedAt != nil else { return }
            checkTimeout()
            if waitStartedAt != nil {
                scheduleTick(serial: serial)
            }
        }
    }

    private func cancelWait() {
        waitStartedAt = nil
        waitSerial &+= 1
        onProgress(nil)
    }
}

private extension ResetObservationPipeline {
    private func commit(_ payload: SnapshotPayload, banked: BankedObservation?) {
        guard pending?.updatedAt == payload.updatedAt,
              readSnapshot()?.updatedAt == payload.updatedAt else { return }
        pending = nil
        cancelWait()
        let priorState = state
        var alerts: [ResetAlert] = []
        var bankedStatus: ResetBankedStatus = .unavailable(lastObservedCount: nil, lastObservedAt: nil)
        var evaluated = false
        var evaluatedCodex = false
        let freshProviders = readFreshProviderNames(for: payload)
        for entry in payload.providers {
            guard let observation = ResetUsageObservation(entry: entry) else { continue }
            guard freshProviders.contains(entry.name) else { continue }
            let count = entry.name == "Codex" ? banked.flatMap(resetBanked) : nil
            let result = ResetAlertDetector.evaluate(
                state: &state, deviceID: deviceID, observation: observation, banked: count
            )
            alerts.append(contentsOf: result.alerts)
            if entry.name == "Codex" {
                bankedStatus = result.bankedStatus
                evaluatedCodex = true
            }
            evaluated = true
        }
        if !evaluated || !evaluatedCodex {
            let countResult = ResetAlertDetector.evaluateBankedCount(
                state: &state, deviceID: deviceID, banked: banked.flatMap(resetBanked)
            )
            alerts.append(contentsOf: countResult.alerts)
            bankedStatus = countResult.bankedStatus
        }
        guard persistState() else {
            state = priorState
            pending = payload
            GradusLog.app.warning("reset alert state could not be saved; delivery will retry")
            onEvaluation(ResetEvaluation(alerts: [], bankedStatus: bankedStatus))
            return
        }
        if let banked {
            processedSidecars.insert(sidecarKey(banked))
        }
        rememberCommitted(payload)
        onEvaluation(ResetEvaluation(alerts: alerts, bankedStatus: bankedStatus))
        onCommit(payload, banked)
    }

    private func acceptLateCount(_ sidecar: BankedObservation, payload: SnapshotPayload) {
        let key = sidecarKey(sidecar)
        guard !processedSidecars.contains(key), let banked = resetBanked(sidecar) else { return }
        let priorState = state
        let codexTime = latestDisplayed?.providers.first(where: { $0.name == "Codex" })?
            .observedAt.flatMap(ResetAlertDetector.parseInstant)
        let result = ResetAlertDetector.evaluateBankedCount(
            state: &state, deviceID: deviceID, banked: banked,
            displayedUsageObservedAt: codexTime
        )
        guard persistState() else {
            state = priorState
            GradusLog.app.warning("reset count state could not be saved; delivery will retry")
            onEvaluation(ResetEvaluation(alerts: [], bankedStatus: result.bankedStatus))
            return
        }
        processedSidecars.insert(key)
        onEvaluation(result)
        onCommit(payload, sidecar)
    }

    private func rememberCommitted(_ payload: SnapshotPayload) {
        committed[payload.updatedAt] = payload
        committedOrder.removeAll { $0 == payload.updatedAt }
        committedOrder.append(payload.updatedAt)
        if committedOrder.count > 3 {
            let oldest = committedOrder.removeFirst()
            committed.removeValue(forKey: oldest)
            processedSidecars = Set(processedSidecars.filter { !$0.hasPrefix("\(oldest)|") })
        }
    }

    private func rereadRollback() {
        guard let payload = readSnapshot() else { return }
        if latestDisplayed != payload {
            latestDisplayed = payload
            onDisplay(payload)
        }
    }

    private func readSnapshot() -> SnapshotPayload? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(SnapshotPayload.self, from: data)
    }

    /// `ProviderEntry` intentionally omits producer bookkeeping fields. Read
    /// the public v2 envelope directly so a cadence-deferred or retained `ok`
    /// entry cannot be mistaken for a new alert edge. The producer sets
    /// `probe_attempted_at` to this snapshot's token only for an actual probe.
    private func readFreshProviderNames(for payload: SnapshotPayload) -> Set<String> {
        guard let data = try? Data(contentsOf: snapshotURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["updated_at"] as? String == payload.updatedAt,
              let entries = root["providers"] as? [[String: Any]]
        else {
            GradusLog.snapshot.warning("public snapshot freshness metadata unavailable; refill evaluation skipped")
            return []
        }
        return Set(entries.compactMap { entry in
            guard entry["ok"] as? Bool == true,
                  let name = entry["name"] as? String,
                  entry["probe_attempted_at"] as? String == payload.updatedAt,
                  entry["observed_at"] is String
            else { return nil }
            return name
        })
    }

    private func readStatus() -> BackgroundAgentStatusFile? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        return try? JSONDecoder().decode(BackgroundAgentStatusFile.self, from: data)
    }

    private func matches(_ sidecar: BankedObservation, payload: SnapshotPayload) -> Bool {
        guard let codex = payload.providers.first(where: { $0.name == "Codex" && $0.ok }),
              let observedAt = codex.observedAt
        else { return false }
        return sidecar.matches(snapshotUpdatedAt: payload.updatedAt, codexObservedAt: observedAt)
    }

    private func resetBanked(_ sidecar: BankedObservation) -> ResetBankedObservation? {
        ResetBankedObservation(
            count: sidecar.count, generation: sidecar.generation, observedAt: sidecar.observedDate
        )
    }

    private func sidecarKey(_ sidecar: BankedObservation) -> String {
        "\(sidecar.snapshotUpdatedAt)|\(sidecar.generation)|\(sidecar.observedAt)|\(sidecar.count)"
    }

    private func isFailure(_ phase: BackgroundAgentStatusFile.Phase?) -> Bool {
        phase == .failed || phase == .cancelled
    }

    private func persistState() -> Bool {
        guard let encoded = try? JSONEncoder().encode(state) else { return false }
        defaults.set(encoded, forKey: Self.stateKey)
        return defaults.data(forKey: Self.stateKey) == encoded
    }
}
