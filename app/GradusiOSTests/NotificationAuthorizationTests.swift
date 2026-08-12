import Foundation
@testable import GradusiOS
import GradusKit
import Testing
import UserNotifications

// Covers the gap that shipped in 1.6.0: `AppDelegate` discarded both results of
// `requestAuthorization(options:) { _, _ in }`, so a user who declined -- or
// who revoked permission from iOS Settings afterwards -- left the in-app
// Notifications toggle reading "on" while every scheduled warning was silently
// dropped by the system. Nothing in the app read the authorization state at all,
// so there was no value a test could have asserted against.

private func authorizationDefaults() -> UserDefaults {
    UserDefaults(suiteName: "gradus-notification-authorization-\(UUID().uuidString)")!
}

private func authorizationCache() -> FileLocalCacheStore {
    FileLocalCacheStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "gradus-notification-authorization-\(UUID().uuidString)", isDirectory: true
        )
    )
}

private struct StubAuthorizationSource: NotificationAuthorizationSource {
    let authorization: NotificationAuthorization

    func currentAuthorization() async -> NotificationAuthorization {
        authorization
    }
}

@Test func unauthorizationStatusMapsProvisionalAndEphemeralToAuthorized() {
    #expect(NotificationAuthorization(.denied) == .denied)
    #expect(NotificationAuthorization(.notDetermined) == .notDetermined)
    #expect(NotificationAuthorization(.authorized) == .authorized)
    // Both deliver notifications, so treating either as denied would show a
    // "you won't see alerts" warning to someone who is receiving them.
    #expect(NotificationAuthorization(.provisional) == .authorized)
    #expect(NotificationAuthorization(.ephemeral) == .authorized)
}

@MainActor
@Test func refreshPublishesTheSystemAuthorizationState() async {
    let viewModel = DashboardViewModel(
        cache: authorizationCache(),
        notificationAuthorizationSource: StubAuthorizationSource(authorization: .denied),
        userDefaults: authorizationDefaults()
    )

    // Honest starting point: nothing has been read yet.
    #expect(viewModel.systemNotificationAuthorization == .notDetermined)

    await viewModel.refreshNotificationAuthorization()

    #expect(viewModel.systemNotificationAuthorization == .denied)
}

@MainActor
@Test func refreshReadsAuthorizationWhileLiveLifecycleIsSuspended() async {
    let viewModel = DashboardViewModel(
        cache: authorizationCache(),
        notificationAuthorizationSource: StubAuthorizationSource(authorization: .denied),
        liveLifecycleGate: LiveLifecycleGate(initiallySuspended: true),
        userDefaults: authorizationDefaults()
    )

    await viewModel.refreshNotificationAuthorization()

    #expect(viewModel.systemNotificationAuthorization == .denied)
}

@MainActor
@Test func refreshWithoutASourceLeavesTheStateUndetermined() async {
    let viewModel = DashboardViewModel(cache: authorizationCache(), userDefaults: authorizationDefaults())

    await viewModel.refreshNotificationAuthorization()

    // A view model built for snapshot tests has no UserNotifications wiring.
    // Guessing either way would put an unverified claim into every baseline.
    #expect(viewModel.systemNotificationAuthorization == .notDetermined)
    #expect(!viewModel.notificationsSuppressedBySystem)
}

@MainActor
@Test func suppressionRequiresBothOurOptInAndASystemDenial() async {
    // Our toggle on + iOS denying: the one state worth surfacing, because every
    // warning transition schedules a notification that is dropped.
    let suppressed = DashboardViewModel(
        cache: authorizationCache(),
        notificationAuthorizationSource: StubAuthorizationSource(authorization: .denied),
        userDefaults: authorizationDefaults()
    )
    await suppressed.setNotificationsEnabled(true)
    await suppressed.refreshNotificationAuthorization()
    #expect(suppressed.notificationsSuppressedBySystem)

    // Denied, but the user already turned warnings off. Nothing is being
    // dropped that they asked for, so a permission warning would be noise.
    let optedOut = DashboardViewModel(
        cache: authorizationCache(),
        notificationAuthorizationSource: StubAuthorizationSource(authorization: .denied),
        userDefaults: authorizationDefaults()
    )
    await optedOut.setNotificationsEnabled(false)
    await optedOut.refreshNotificationAuthorization()
    #expect(!optedOut.notificationsSuppressedBySystem)

    // Authorized: the feature works, nothing to say.
    let working = DashboardViewModel(
        cache: authorizationCache(),
        notificationAuthorizationSource: StubAuthorizationSource(authorization: .authorized),
        userDefaults: authorizationDefaults()
    )
    await working.setNotificationsEnabled(true)
    await working.refreshNotificationAuthorization()
    #expect(!working.notificationsSuppressedBySystem)
}

@MainActor
@Test func aSystemDenialDoesNotSilentlyFlipOurOwnOptIn() async {
    // The warning subscription is a silent content-available push whose side
    // effect is waking the app to sync; that still works while alerts are
    // suppressed. So a denial must not turn our opt-in off -- doing so would
    // cost the user background sync to "fix" a display permission.
    let viewModel = DashboardViewModel(
        cache: authorizationCache(),
        notificationAuthorizationSource: StubAuthorizationSource(authorization: .denied),
        userDefaults: authorizationDefaults()
    )
    await viewModel.setNotificationsEnabled(true)

    await viewModel.refreshNotificationAuthorization()

    #expect(viewModel.notificationsEnabled)
    #expect(viewModel.notificationsToggleError == nil)
}
