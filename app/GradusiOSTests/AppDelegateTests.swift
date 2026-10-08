@testable import GradusiOS
import Testing
import UIKit
import UserNotifications

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
    func failedRemoteRegistrationIsRetryableOnForeground() throws {
        var registrationCount = 0
        var failureCount = 0
        let diagnostics = PushDiagnostics(fileURL: diagnosticFileURL())
        let delegate = AppDelegate(
            clearBadge: {},
            registerForRemoteNotifications: { _ in registrationCount += 1 },
            pushDiagnostics: diagnostics
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

        let receipt = try #require(diagnostics.loadReceipt())
        #expect(receipt.events.map(\.stage) == [.apnsRegistration])
        #expect(receipt.events.map(\.status) == [.failure])
        let serialized = try String(contentsOf: diagnostics.fileURL, encoding: .utf8)
        #expect(!serialized.contains("TestRegistrationError"))
    }

    @Test
    func recordsAPNsRegistrationAndRemoteNotificationWithoutPersistingPayload() async throws {
        let diagnostics = PushDiagnostics(fileURL: diagnosticFileURL())
        let delegate = AppDelegate(clearBadge: {}, pushDiagnostics: diagnostics)
        delegate.onRemoteNotification = {}

        delegate.application(UIApplication.shared, didRegisterForRemoteNotificationsWithDeviceToken: Data([0x01, 0x02]))
        let result = await delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: ["provider": "private-payload", "account": "private-account"]
        )

        #expect(result == .newData)
        let receipt = try #require(diagnostics.loadReceipt())
        #expect(
            receipt.events.map(\.stage) == [
                .apnsRegistration, .remoteNotificationEntry, .remoteNotificationCompletion
            ]
        )
        #expect(receipt.events.map(\.status) == [.success, .received, .newData])
        #expect(receipt.events.allSatisfy { $0.timestamp.hasSuffix("Z") })

        let data = try Data(contentsOf: diagnostics.fileURL)
        try assertOnlyAllowlistedReceiptFields(data)
        let serialized = try #require(String(data: data, encoding: .utf8))
        #expect(!serialized.contains("private-payload"))
        #expect(!serialized.contains("private-account"))
        #expect(!serialized.contains("0102"))
    }

    @Test
    func diagnosticsRetainOnlyTheMostRecentThirtyTwoEvents() throws {
        let diagnostics = PushDiagnostics(fileURL: diagnosticFileURL())

        for _ in 0 ..< 40 {
            diagnostics.record(stage: .remoteNotificationEntry, status: .received)
        }

        let receipt = try #require(diagnostics.loadReceipt())
        #expect(receipt.events.count == 32)
        #expect(receipt.events.allSatisfy { $0.stage == .remoteNotificationEntry })
        #expect(receipt.events.allSatisfy { $0.status == .received })
    }

    @Test
    func diagnosticsRejectUnknownSchemaAndReplaceItOnNextRecord() throws {
        let fileURL = diagnosticFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"schemaVersion":999,"events":[]}"#.utf8).write(to: fileURL)
        let diagnostics = PushDiagnostics(fileURL: fileURL)

        #expect(diagnostics.loadReceipt() == nil)
        diagnostics.record(stage: .apnsRegistration, status: .success)

        let receipt = try #require(diagnostics.loadReceipt())
        #expect(receipt.schemaVersion == PushDiagnostics.schemaVersion)
        #expect(receipt.events.count == 1)
        #expect(receipt.events.first?.stage == .apnsRegistration)
        #expect(receipt.events.first?.status == .success)
    }

    private struct TestRegistrationError: Error {}

    private func diagnosticFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gradus-push-diagnostics-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("push-diagnostics.json")
    }

    private func assertOnlyAllowlistedReceiptFields(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        let receipt = try #require(object as? [String: Any])
        #expect(Set(receipt.keys) == ["schemaVersion", "events"])
        let events = try #require(receipt["events"] as? [[String: Any]])
        #expect(events.allSatisfy { Set($0.keys) == ["stage", "status", "timestamp"] })
    }

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

    /// Foreground syncs consume reset and warning transitions, so a foreground
    /// notification must be presented rather than dropped by iOS.
    @Test
    func presentsLocalAlertsWhileForeground() {
        let delegate: UNUserNotificationCenterDelegate = AppDelegate(clearBadge: {})
        #expect(delegate.responds(to: #selector(
            UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)
        )))
        #expect(AppDelegate.foregroundPresentationOptions.contains(.banner))
        #expect(AppDelegate.foregroundPresentationOptions.contains(.list))
    }
}
