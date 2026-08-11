import Testing
import UIKit
@testable import GradusiOS

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

    /// The missing wake-up behind the 1.6.0 gap's worst case: a first-launch
    /// denial. `refreshNotificationAuthorization()` on `.task` races the prompt
    /// and reads `.notDetermined`, and a permission alert does not reliably
    /// send the scene back through `.active`, so without this callback someone
    /// who taps "Don't Allow" sees no warning until an unrelated foreground
    /// cycle. Holding `resolve` rather than calling it immediately checks both
    /// halves: nothing is read while the prompt is still open, and the read
    /// happens as soon as it is answered.
    @Test
    func launchRereadsPermissionOnlyOnceThePromptIsAnswered() async {
        var resolve: (() -> Void)?
        let delegate = AppDelegate(
            clearBadge: {},
            requestNotificationAuthorization: { _, resolved in resolve = resolved },
            registerForRemoteNotifications: { _ in })
        var rereadCount = 0
        delegate.onAuthorizationResolved = { rereadCount += 1 }

        #expect(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))

        #expect(rereadCount == 0)

        resolve?()
        while rereadCount == 0 { await Task.yield() }

        #expect(rereadCount == 1)
    }

    @Test
    func freshInstallDefersNotificationWorkUntilLiveModeIsChosen() {
        var clearCount = 0
        var authorizationRequestCount = 0
        let delegate = AppDelegate(
            clearBadge: { clearCount += 1 },
            requestNotificationAuthorization: { _, _ in authorizationRequestCount += 1 },
            liveModeEnabled: { false })

        #expect(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
        #expect(clearCount == 0)
        #expect(authorizationRequestCount == 0)

        delegate.beginLiveLifecycle(UIApplication.shared)
        #expect(clearCount == 1)
        #expect(authorizationRequestCount == 1)
    }

    @Test
    func sampleModeSuppressesRemoteNotificationWork() async {
        var callbackCount = 0
        let delegate = AppDelegate(clearBadge: {})
        delegate.liveActivitySuppressed = true
        delegate.onRemoteNotification = { callbackCount += 1 }

        let result = await delegate.application(
            UIApplication.shared, didReceiveRemoteNotification: [:])

        #expect(result == .noData)
        #expect(callbackCount == 0)
    }

    /// Sample entry must drain a live authorization request that is already
    /// pending, then suppress the registration callback. This is run for both
    /// device surfaces because the transition is shared by iPhone and iPad.
    @Test(arguments: ["iPhone", "iPad"])
    func sampleEntryQuiescesBlockedNotificationAuthorization(_ device: String) async {
        var resolve: (() -> Void)?
        var authorizationRequestCount = 0
        var registrationCount = 0
        let delegate = AppDelegate(
            clearBadge: {},
            requestNotificationAuthorization: { _, completion in
                authorizationRequestCount += 1
                resolve = completion
            },
            registerForRemoteNotifications: { _ in registrationCount += 1 })
        let gate = LiveLifecycleGate()

        let liveStart = Task { @MainActor in
            await gate.withOperation { epoch in
                guard gate.isCurrent(epoch) else { return }
                delegate.beginLiveLifecycle()
                await delegate.awaitAuthorizationResolution()
            }
        }
        while authorizationRequestCount == 0 { await Task.yield() }

        delegate.liveActivitySuppressed = true
        let enterSample = Task { @MainActor in await gate.suspend() }
        while !gate.isSuspended { await Task.yield() }

        #expect(registrationCount == 0, "\(device) registered before authorization quiesced")
        resolve?()
        await enterSample.value
        await liveStart.value

        #expect(authorizationRequestCount == 1)
        #expect(registrationCount == 0, "\(device) registered after sample entry")
    }
}
