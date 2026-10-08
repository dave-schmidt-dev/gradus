import Foundation
import GradusKit

/// Warning-alert opt-in (`notificationsEnabled`) and the system-level
/// authorization it depends on. P5/T5.1.
public extension DashboardViewModel {
    /// Reset alerts have independent consent; the silent zone push and warning
    /// subscription remain controlled by their existing paths.
    var resetAlertsSuppressedBySystem: Bool {
        (bankedResetAlertsEnabled || usageRefillAlertsEnabled)
            && systemNotificationAuthorization == .denied
    }

    static let shortWindowRefillAlertsEnabledKey = "shortWindowRefillAlertsEnabled"

    /// Whether 5-hour refills alert as well as weekly ones; off until the user
    /// turns it on. Read straight from the defaults so it needs no stored
    /// property, and `setShortWindowRefillAlertsEnabled` publishes the change.
    var shortWindowRefillAlertsEnabled: Bool {
        userDefaults.bool(forKey: Self.shortWindowRefillAlertsEnabledKey)
    }

    func setBankedResetAlertsEnabled(_ enabled: Bool) {
        guard bankedResetAlertsEnabled != enabled else { return }
        bankedResetAlertsEnabled = enabled
        userDefaults.set(enabled, forKey: Self.bankedResetAlertsEnabledKey)
    }

    func setUsageRefillAlertsEnabled(_ enabled: Bool) {
        guard usageRefillAlertsEnabled != enabled else { return }
        usageRefillAlertsEnabled = enabled
        userDefaults.set(enabled, forKey: Self.usageRefillAlertsEnabledKey)
    }

    func setShortWindowRefillAlertsEnabled(_ enabled: Bool) {
        guard shortWindowRefillAlertsEnabled != enabled else { return }
        objectWillChange.send()
        userDefaults.set(enabled, forKey: Self.shortWindowRefillAlertsEnabledKey)
    }

    /// True when our own opt-in is on but iOS will not display the result. The
    /// only state worth surfacing: every warning transition schedules a
    /// notification that is silently dropped, so the feature reads as broken
    /// rather than off.
    ///
    /// Deliberately does *not* imply the toggle should be disabled. The warning
    /// subscription is a silent content-available push whose side effect is
    /// waking the app to sync; that still works while alerts are suppressed, so
    /// turning it off would cost the user something real.
    var notificationsSuppressedBySystem: Bool {
        notificationsEnabled && systemNotificationAuthorization == .denied
    }

    /// P5/T5.1: toggle-on is best-effort/optimistic (mirrors the existing
    /// enable-path semantics of `subscribeToWarnings()`, called via
    /// `GradusiOSApp`'s `.onChange(of: notificationsEnabled)`). Toggle-off
    /// is success-gated (CR-5): `notificationsEnabled` only flips to
    /// `false` once `unsubscribeFromWarnings()` actually succeeds, so the
    /// UI never claims "off" while a stale `CKQuerySubscription` keeps
    /// firing server-side. On failure the value is left untouched (i.e.
    /// still `true`) and `notificationsToggleError` is set for an inline
    /// row message.
    func setNotificationsEnabled(_ enabled: Bool) async {
        guard enabled != notificationsEnabled else { return }
        if enabled {
            notificationsEnabled = true
            userDefaults.set(true, forKey: Self.notificationsEnabledKey)
            notificationsToggleError = nil
            return
        }
        guard let subscriptionManager else {
            // No live subscription path configured (e.g. a view model built
            // without CloudKit wiring) -- nothing server-side to fail, so
            // there's nothing to gate on.
            notificationsEnabled = false
            userDefaults.set(false, forKey: Self.notificationsEnabledKey)
            notificationsToggleError = nil
            return
        }
        let unsubscribe: () async -> Void = {
            do {
                try await subscriptionManager.unsubscribeFromWarnings()
                self.notificationsEnabled = false
                self.userDefaults.set(false, forKey: Self.notificationsEnabledKey)
                self.notificationsToggleError = nil
            } catch {
                self.notificationsToggleError =
                    "Couldn't turn off notifications -- check your connection and try again."
            }
        }
        if let liveLifecycleGate {
            await liveLifecycleGate.withOperation { _ in await unsubscribe() }
        } else {
            await unsubscribe()
        }
    }

    /// Re-reads the system authorization state. Called on launch and on every
    /// foreground transition, since the user can only change it by leaving the
    /// app for iOS Settings.
    ///
    /// No-ops without a source rather than assuming a value: a view model built
    /// for snapshot tests has no UserNotifications wiring, and defaulting to
    /// `.denied` would put a permission warning into every baseline while
    /// defaulting to `.authorized` would assert something unverified.
    /// `.notDetermined` is the honest starting point and stays put.
    func refreshNotificationAuthorization() async {
        guard let notificationAuthorizationSource else { return }
        // This is a local UserNotifications read, not live iCloud work. UI
        // fixtures intentionally suspend CloudKit through the lifecycle gate
        // but still need an accurate permission state to render their alert
        // recovery controls deterministically.
        systemNotificationAuthorization = await notificationAuthorizationSource.currentAuthorization()
        resetAlertAuthorizationRequestInProgress = false
    }

    /// Entry point for a content-available push. The push can cold-launch the
    /// app in the background, where the scene's live lifecycle never runs, so
    /// the iCloud account and notification permission are still unread. Read
    /// both first: otherwise the delta sync is skipped, or a detected reset
    /// advances the persisted cursor while the `.notDetermined` permission
    /// gate drops its notification for good.
    func handleBackgroundRemoteNotification() async {
        await refreshNotificationAuthorization()
        if accountStatus != .available {
            await refreshAccountStatus()
        }
        await handleRemoteNotification()
    }
}

extension DashboardViewModel {
    /// Called only after a successful full or delta fetch. Re-evaluating the
    /// cached complete set is safe: source observedAt cursors dedupe unchanged
    /// entries, including a late count at the same Codex usage timestamp.
    func evaluateResetStatuses(_ statuses: [ProviderStatus], schedule: Bool = true) {
        let priorState = resetAlertState
        var alerts: [ResetAlert] = []
        var codexRecord: ProviderStatus?
        var codexResult: ResetEvaluation?

        for status in statuses.sorted(by: { $0.providerName < $1.providerName }) {
            guard Self.isResetProvider(status.providerName) else { continue }
            if status.providerName == "Codex" {
                codexRecord = status
            }
            guard let result = evaluateResetStatus(status) else { continue }
            alerts += result.alerts
            if status.providerName == "Codex" {
                codexResult = result
            }
        }
        let status = currentBankedStatus(record: codexRecord, result: codexResult)
        guard persistResetAlertState() else {
            resetAlertState = priorState
            return
        }
        bankedResetStatus = status
        if schedule {
            scheduleResetAlerts(alerts)
        }
    }

    private func scheduleResetAlerts(_ alerts: [ResetAlert]) {
        guard systemNotificationAuthorization == .authorized else { return }
        for alert in alerts {
            switch alert {
            case .bankedGrant where bankedResetAlertsEnabled:
                resetNotificationScheduler?.scheduleResetNotification(alert)
            case let .usageRefill(_, windowID)
                where usageRefillAlertsEnabled
                && (shortWindowRefillAlertsEnabled || ResetAlertDetector.isWeeklyWindow(windowID)):
                resetNotificationScheduler?.scheduleResetNotification(alert)
            default: break
            }
        }
    }

    private func evaluateResetStatus(_ status: ProviderStatus) -> ResetEvaluation? {
        guard let observation = ResetUsageObservation(status: status) else { return nil }
        let banked = status.providerName == "Codex" ? Self.bankedObservation(status) : nil
        let matchingBanked = banked?.observedAt == observation.observedAt ? banked : nil
        return ResetAlertDetector.evaluate(
            state: &resetAlertState, deviceID: resetDeviceID,
            observation: observation, banked: matchingBanked
        )
    }

    private func currentBankedStatus(
        record: ProviderStatus?, result: ResetEvaluation?
    ) -> ResetBankedStatus {
        if let result, Self.hasObservedCount(result.bankedStatus) {
            return result.bankedStatus
        }
        let prior = ResetAlertDetector.evaluateBankedCount(
            state: &resetAlertState, deviceID: resetDeviceID, banked: nil
        ).bankedStatus
        if Self.hasObservedCount(prior) {
            return prior
        }
        // A carried count belongs under Last observed. It is not a fresh
        // grant and must not advance the alert cursor.
        if let record, let banked = Self.bankedObservation(record) {
            return .unavailable(lastObservedCount: banked.count, lastObservedAt: banked.observedAt)
        }
        return prior
    }

    private static func hasObservedCount(_ status: ResetBankedStatus) -> Bool {
        switch status {
        case .current: true
        case let .unavailable(lastObservedCount, _): lastObservedCount != nil
        }
    }

    private func persistResetAlertState() -> Bool {
        guard let encoded = try? JSONEncoder().encode(resetAlertState) else { return false }
        userDefaults.set(encoded, forKey: Self.resetAlertStateKey)
        return userDefaults.data(forKey: Self.resetAlertStateKey) == encoded
    }

    private static func isResetProvider(_ name: String) -> Bool {
        name == "Codex" || name == "Claude"
    }

    private static func bankedObservation(_ status: ProviderStatus) -> ResetBankedObservation? {
        guard case let .double(rawCount)? = status.data["banked_reset_count"],
              rawCount.isFinite, rawCount.rounded() == rawCount,
              (0 ... 1_000_000).contains(rawCount),
              case let .string(generation)? = status.data["banked_reset_generation"],
              let parsedGeneration = UUID(uuidString: generation),
              parsedGeneration.uuidString.lowercased() == generation,
              case let .string(rawObservedAt)? = status.data["banked_reset_observed_at"],
              let observedAt = ResetAlertDetector.parseInstant(rawObservedAt)
        else { return nil }
        return ResetBankedObservation(
            count: Int(rawCount), generation: generation, observedAt: observedAt
        )
    }
}
