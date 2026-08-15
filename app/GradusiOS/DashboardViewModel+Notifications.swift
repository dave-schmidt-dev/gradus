import Foundation

/// Warning-alert opt-in (`notificationsEnabled`) and the system-level
/// authorization it depends on. P5/T5.1.
public extension DashboardViewModel {
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
    }
}
