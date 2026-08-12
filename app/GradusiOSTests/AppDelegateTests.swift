@testable import GradusiOS
import Testing
import UIKit

@MainActor
struct AppDelegateTests {
    @Test
    func clearsBadgeWhenApplicationBecomesActive() {
        var clearCount = 0
        let delegate = AppDelegate {
            clearCount += 1
        }

        delegate.applicationDidBecomeActive(UIApplication.shared)

        #expect(clearCount == 1)
    }

    @Test
    func clearsBadgeWhenApplicationReturnsToForeground() {
        var clearCount = 0
        let delegate = AppDelegate {
            clearCount += 1
        }

        delegate.applicationWillEnterForeground(UIApplication.shared)

        #expect(clearCount == 1)
    }

    @Test
    func freshLiveLaunchRegistersWithoutPromptOrWait() async {
        var registrationCount = 0
        var authorizationRequestCount = 0
        let delegate = AppDelegate(
            clearBadge: {},
            requestNotificationAuthorization: { _, _ in
                authorizationRequestCount += 1
            },
            registerForRemoteNotifications: { _ in registrationCount += 1 }
        )

        #expect(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
        #expect(registrationCount == 1)
        #expect(authorizationRequestCount == 0)
        await delegate.awaitAuthorizationResolution()
        #expect(registrationCount == 1)
    }

    @Test
    func liveRegistrationStillOccursWhenLiveModeWasPreviouslyConfirmed() {
        var clearCount = 0
        var registrationCount = 0
        let delegate = AppDelegate(
            clearBadge: { clearCount += 1 },
            registerForRemoteNotifications: { _ in registrationCount += 1 }
        )

        #expect(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
        #expect(clearCount == 1)
        #expect(registrationCount == 1)
    }

    @Test
    func warningAlertRequestIsExplicitAndLatestIntentWins() async {
        var completions: [(Bool) -> Void] = []
        let delegate = AppDelegate(
            clearBadge: {},
            requestNotificationAuthorization: { _, completion in completions.append(completion) }
        )

        delegate.beginLiveLifecycle()
        delegate.setWarningAlertsEnabled(true)
        #expect(delegate.warningAlertAuthorization == .requesting)
        #expect(completions.count == 1)

        delegate.setWarningAlertsEnabled(false)
        completions[0](true)
        await Task.yield()
        #expect(delegate.warningAlertAuthorization == .off)

        delegate.setWarningAlertsEnabled(true)
        #expect(completions.count == 2)
        completions[1](false)
        while delegate.warningAlertAuthorization == .requesting {
            await Task.yield()
        }
        #expect(delegate.warningAlertAuthorization == .denied)
    }

    @Test
    func sampleModeSuppressesRemoteNotificationWork() async {
        var callbackCount = 0
        let delegate = AppDelegate(clearBadge: {})
        delegate.liveActivitySuppressed = true
        delegate.onRemoteNotification = { callbackCount += 1 }

        let result = await delegate.application(
            UIApplication.shared, didReceiveRemoteNotification: [:]
        )

        #expect(result == .noData)
        #expect(callbackCount == 0)
    }

    @Test
    func failedRemoteRegistrationIsRetryableOnForeground() {
        var registrationCount = 0
        var failureCount = 0
        let delegate = AppDelegate(
            clearBadge: {},
            registerForRemoteNotifications: { _ in registrationCount += 1 }
        )
        delegate.onRemoteRegistrationFailure = { failureCount += 1 }

        delegate.beginLiveLifecycle(UIApplication.shared)
        #expect(registrationCount == 1)

        delegate.application(
            UIApplication.shared,
            didFailToRegisterForRemoteNotificationsWithError: TestRegistrationError()
        )
        #expect(failureCount == 1)
        delegate.applicationWillEnterForeground(UIApplication.shared)
        #expect(registrationCount == 2)
    }

    private struct TestRegistrationError: Error {}

    @Test(arguments: ["iPhone", "iPad"])
    func sampleEntryDoesNotStartRemoteRegistration(_ device: String) async {
        var registrationCount = 0
        let delegate = AppDelegate(
            clearBadge: {},
            registerForRemoteNotifications: { _ in registrationCount += 1 }
        )
        let gate = LiveLifecycleGate()

        let liveStart = Task { @MainActor in
            await gate.withOperation { epoch in
                guard gate.isCurrent(epoch) else { return }
                delegate.beginLiveLifecycle()
                await delegate.awaitAuthorizationResolution()
            }
        }
        delegate.liveActivitySuppressed = true
        let enterSample = Task { @MainActor in await gate.suspend() }
        while !gate.isSuspended {
            await Task.yield()
        }

        #expect(registrationCount == 0, "\(device) registered in sample mode")
        await enterSample.value
        await liveStart.value

        #expect(registrationCount == 0, "\(device) registered after sample entry")
    }
}
