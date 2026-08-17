import GradusKit
import UIKit

/// Foreground-only lease driver. Background deletion is best effort; the
/// ten-minute expiry enforced by Mac Settings handles crashes and termination.
@MainActor
final class DevicePresenceLifecycle {
    private let writer: DevicePresenceLeaseWriter?
    private let eligibility: @MainActor () -> (liveMode: Bool, accountAvailable: Bool)
    private var renewalTask: Task<Void, Never>?
    private var sampleMode = false

    init(
        client: (any DevicePresenceClient)?,
        defaults: UserDefaults = .standard,
        eligibility: @escaping @MainActor () -> (liveMode: Bool, accountAvailable: Bool) = { (true, true) }
    ) {
        self.eligibility = eligibility
        guard let client else {
            writer = nil
            return
        }
        let name: DevicePresenceName = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        let installationID = DevicePresenceInstallationStore(defaults: defaults).installationID()
        writer = DevicePresenceLeaseWriter(
            client: client,
            lease: DevicePresenceLease(installationID: installationID, displayName: name)
        )
    }

    func start(liveMode: Bool, accountAvailable: Bool, sampleMode: Bool, migrationRecovery: Bool = false) {
        stopRenewingOnly()
        self.sampleMode = sampleMode
        guard liveMode, accountAvailable, !sampleMode, !migrationRecovery, writer != nil else { return }
        renewCurrent()
        renewalTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(DevicePresence.renewalInterval)) } catch { return }
                guard let self else { return }
                renewCurrent()
            }
        }
    }

    func stop() {
        stopRenewingOnly()
        guard let writer else { return }
        Task { await writer.remove() }
    }

    private func stopRenewingOnly() {
        renewalTask?.cancel()
        renewalTask = nil
    }

    @discardableResult
    func renewNow(
        liveMode: Bool,
        accountAvailable: Bool,
        sampleMode: Bool,
        migrationRecovery: Bool = false
    ) async -> Bool {
        guard let writer else { return false }
        return await writer.renew(
            liveMode: liveMode, accountAvailable: accountAvailable,
            sampleMode: sampleMode, migrationRecovery: migrationRecovery
        )
    }

    @discardableResult
    func removeNow() async -> Bool {
        await writer?.remove() ?? false
    }

    private func renewCurrent() {
        guard let writer else { return }
        let current = eligibility()
        guard current.liveMode, current.accountAvailable, !sampleMode else { return }
        Task {
            _ = await writer.renew(liveMode: true, accountAvailable: true, sampleMode: false)
        }
    }
}
