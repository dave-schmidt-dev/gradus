import Foundation
@testable import GradusMac
import Testing
import UserNotifications

@MainActor
private final class FakeResetScheduler: ResetNotificationScheduling {
    var current: ResetNotificationAuthorization = .notDetermined
    var requestResult: ResetNotificationAuthorization = .authorized
    var authorizationReads = 0
    var requests = 0
    var events: [ResetNotificationEvent] = []
    var suspendedRequest: CheckedContinuation<ResetNotificationAuthorization, Never>?
    var shouldSuspendRequest = false

    func authorization() async -> ResetNotificationAuthorization {
        authorizationReads += 1
        return current
    }

    func requestAuthorization() async -> ResetNotificationAuthorization {
        requests += 1
        if shouldSuspendRequest {
            return await withCheckedContinuation { suspendedRequest = $0 }
        }
        return requestResult
    }

    func schedule(_ event: ResetNotificationEvent) {
        events.append(event)
    }
}

@MainActor
private final class FakeBankedAuthorizer: BankedBackgroundAccessAuthorizing {
    var calls = 0
    var result = false
    var suspendedRequest: CheckedContinuation<Bool, Never>?
    var shouldSuspend = false

    func authorize() async -> Bool {
        calls += 1
        if shouldSuspend {
            return await withCheckedContinuation { suspendedRequest = $0 }
        }
        return result
    }
}

private final class InertAgentService: BackgroundAgentServicing {
    var registration: BackgroundAgentRegistration = .notRegistered
    func register() throws {}
    func unregister() throws {}
}

@MainActor
private func makeResetModel(
    scheduler: FakeResetScheduler,
    authorizer: FakeBankedAuthorizer,
    defaults: UserDefaults
) -> PublisherViewModel {
    PublisherViewModel(
        defaults: defaults,
        backgroundAgent: BackgroundAgentManager(
            service: InertAgentService(),
            statusFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("gradus-reset-test-absent-\(UUID().uuidString)")
        ),
        resetNotificationScheduler: scheduler,
        bankedAccessAuthorizer: authorizer
    )
}

private func resetDefaults(_ test: String) -> (String, UserDefaults)? {
    let suite = "com.zerodelta.gradus.mac.tests.reset-notification.\(test)"
    guard let defaults = scratchDefaults(suite) else { return nil }
    return (suite, defaults)
}

@Test @MainActor func resetPreferencesStartOffAndRemainIndependent() async throws {
    let scheduler = FakeResetScheduler()
    let authorizer = FakeBankedAuthorizer()
    let (suite, defaults) = try #require(resetDefaults(#function))
    defer { removeScratchDefaultsSuite(suite, using: defaults) }
    let model = makeResetModel(scheduler: scheduler, authorizer: authorizer, defaults: defaults)

    #expect(!model.resetGrantAlertsEnabled)
    #expect(!model.resetRefillAlertsEnabled)
    #expect(scheduler.authorizationReads == 0)
    #expect(scheduler.requests == 0)
    #expect(authorizer.calls == 0)

    scheduler.current = .authorized
    await model.setResetGrantAlertsEnabled(true)
    #expect(model.resetGrantAlertsEnabled)
    #expect(!model.resetRefillAlertsEnabled)
    #expect(defaults.bool(forKey: PublisherViewModel.resetGrantAlertsEnabledKey))
    #expect(!defaults.bool(forKey: PublisherViewModel.resetRefillAlertsEnabledKey))
    #expect(scheduler.requests == 0)

    let restored = makeResetModel(scheduler: scheduler, authorizer: authorizer, defaults: defaults)
    #expect(restored.resetGrantAlertsEnabled)
    #expect(!restored.resetRefillAlertsEnabled)
}

@Test @MainActor func permissionPromptRunsOnlyAfterExplicitOptInAndHasRequestingState() async throws {
    let scheduler = FakeResetScheduler()
    scheduler.shouldSuspendRequest = true
    let (suite, defaults) = try #require(resetDefaults(#function))
    defer { removeScratchDefaultsSuite(suite, using: defaults) }
    let model = makeResetModel(
        scheduler: scheduler, authorizer: FakeBankedAuthorizer(), defaults: defaults
    )

    await model.refreshResetNotificationAuthorization()
    #expect(scheduler.authorizationReads == 0)
    let task = Task { await model.setResetRefillAlertsEnabled(true) }
    while scheduler.suspendedRequest == nil {
        await Task.yield()
    }
    #expect(model.resetNotificationAuthorization == .requesting)
    #expect(scheduler.requests == 1)
    await model.setResetGrantAlertsEnabled(true)
    #expect(scheduler.requests == 1)
    scheduler.suspendedRequest?.resume(returning: .denied)
    await task.value
    #expect(model.resetNotificationAuthorization == .denied)

    // A denial may be repaired in System Settings, but toggling again cannot
    // present a second system prompt to override that decision.
    scheduler.current = .denied
    await model.setResetGrantAlertsEnabled(false)
    await model.setResetGrantAlertsEnabled(true)
    #expect(scheduler.requests == 1)
}

@Test @MainActor func optedInAlertNeedsCurrentSystemPermissionAndDoesNotChangeWarnings() async throws {
    let scheduler = FakeResetScheduler()
    let (suite, defaults) = try #require(resetDefaults(#function))
    defer { removeScratchDefaultsSuite(suite, using: defaults) }
    let model = makeResetModel(
        scheduler: scheduler, authorizer: FakeBankedAuthorizer(), defaults: defaults
    )
    let grant = ResetNotificationEvent(kind: .grant, providerName: "Codex")
    let refill = ResetNotificationEvent(kind: .refill, providerName: "Claude", windowLabel: "weekly")

    await model.scheduleResetAlert(grant)
    #expect(scheduler.events.isEmpty)
    scheduler.current = .authorized
    await model.setResetGrantAlertsEnabled(true)
    await model.scheduleResetAlert(grant)
    await model.scheduleResetAlert(refill)
    #expect(scheduler.events == [grant])

    await model.setResetRefillAlertsEnabled(true)
    await model.scheduleResetAlert(refill)
    #expect(scheduler.events == [grant, refill])
    scheduler.current = .denied
    await model.scheduleResetAlert(grant)
    #expect(scheduler.events == [grant, refill])
    #expect(model.resetNotificationAuthorization == .denied)
}

@Test @MainActor func bankedUnavailableRetainsOnlyLabeledLastObservation() throws {
    let (suite, defaults) = try #require(resetDefaults(#function))
    defer { removeScratchDefaultsSuite(suite, using: defaults) }
    let model = makeResetModel(
        scheduler: FakeResetScheduler(), authorizer: FakeBankedAuthorizer(), defaults: defaults
    )
    #expect(model.bankedCreditStatusText == "Unavailable")
    #expect(model.lastObservedBankedCreditText == nil)
    model.updateBankedCreditObservation(count: 3)
    #expect(model.bankedCreditStatusText == "3 available")
    model.updateBankedCreditObservation(count: nil)
    #expect(model.bankedCreditStatusText == "Unavailable")
    #expect(model.lastObservedBankedCreditText == "Last observed: 3 available")
    model.updateBankedCreditObservation(count: -1, lastObservedCount: 4)
    #expect(model.bankedCreditStatusText == "Unavailable")
    #expect(model.lastObservedBankedCreditText == "Last observed: 4 available")
}

@Test @MainActor func sidecarWaitProgressIsVisibleButNeverRepeatsCallerDetail() throws {
    let (suite, defaults) = try #require(resetDefaults(#function))
    defer { removeScratchDefaultsSuite(suite, using: defaults) }
    let model = makeResetModel(
        scheduler: FakeResetScheduler(), authorizer: FakeBankedAuthorizer(), defaults: defaults
    )
    #expect(model.resetObservationProgress == nil)
    model.updateResetObservationProgress("private path or account identifier")
    #expect(model.resetObservationProgress == "Waiting for reset observation…")
    model.updateResetObservationProgress(nil)
    #expect(model.resetObservationProgress == nil)
}

@Test @MainActor func attendedBackgroundAccessRunsOnlyFromAction() async throws {
    let authorizer = FakeBankedAuthorizer()
    authorizer.shouldSuspend = true
    let (suite, defaults) = try #require(resetDefaults(#function))
    defer { removeScratchDefaultsSuite(suite, using: defaults) }
    let model = makeResetModel(
        scheduler: FakeResetScheduler(), authorizer: authorizer, defaults: defaults
    )
    #expect(authorizer.calls == 0)
    let task = Task { await model.authorizeBankedBackgroundAccess() }
    while authorizer.suspendedRequest == nil {
        await Task.yield()
    }
    #expect(model.bankedAccessRecoveryState == .requesting)
    #expect(authorizer.calls == 1)
    authorizer.suspendedRequest?.resume(returning: false)
    await task.value
    #expect(model.bankedAccessRecoveryState == .denied)
    authorizer.shouldSuspend = false
    authorizer.result = true
    await model.authorizeBankedBackgroundAccess()
    #expect(authorizer.calls == 2)
    #expect(model.bankedAccessRecoveryState == .allowed)
}

@Test func resetNotificationCopyAndSystemStatusMappingStayGeneric() {
    let grant = ResetNotificationEvent(kind: .grant, providerName: "Codex", increase: 1, currentCount: 2)
    let multiGrant = ResetNotificationEvent(kind: .grant, providerName: "Codex", increase: 2, currentCount: 3)
    let refill = ResetNotificationEvent(kind: .refill, providerName: "Claude", windowLabel: "five_hour")
    #expect(grant.title == "New banked resets")
    #expect(grant.body == "Codex added 1 banked reset. 2 available.")
    #expect(multiGrant.body == "Codex added 2 banked resets. 3 available.")
    #expect(refill.title == "Usage refilled")
    #expect(refill.body == "Claude 5 Hour usage is available again.")
    #expect(!grant.body.lowercased().contains("keychain"))
    #expect(ResetNotificationAuthorization(.denied) == .denied)
    #expect(ResetNotificationAuthorization(.provisional) == .authorized)
    #expect(ResetNotificationAuthorization(.notDetermined) == .notDetermined)
}

@Test @MainActor func shortWindowRefillsNeedTheirOwnOptIn() async throws {
    let scheduler = FakeResetScheduler()
    scheduler.current = .authorized
    let (suite, defaults) = try #require(resetDefaults(#function))
    defer { removeScratchDefaultsSuite(suite, using: defaults) }
    let model = makeResetModel(
        scheduler: scheduler, authorizer: FakeBankedAuthorizer(), defaults: defaults
    )
    let weekly = ResetNotificationEvent(kind: .refill, providerName: "Claude", windowLabel: "weekly")
    let fiveHour = ResetNotificationEvent(kind: .refill, providerName: "Claude", windowLabel: "five_hour")
    #expect(!model.resetShortWindowRefillAlertsEnabled)

    await model.setResetRefillAlertsEnabled(true)
    await model.scheduleResetAlert(fiveHour)
    await model.scheduleResetAlert(weekly)
    #expect(scheduler.events == [weekly])

    model.setResetShortWindowRefillAlertsEnabled(true)
    #expect(defaults.bool(forKey: PublisherViewModel.resetShortWindowRefillAlertsEnabledKey))
    await model.scheduleResetAlert(fiveHour)
    #expect(scheduler.events == [weekly, fiveHour])
}
