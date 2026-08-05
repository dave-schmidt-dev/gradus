import CloudKit
import Foundation
import Testing

@testable import GradusKit

private actor MockAccountStatusSource: AccountStatusSource {
    var nextStatus: Result<CKAccountStatus, Error> = .success(.available)
    private(set) var callCount = 0

    func currentAccountStatus() async throws -> CKAccountStatus {
        callCount += 1
        switch nextStatus {
        case .success(let status): return status
        case .failure(let error): throw error
        }
    }

    func setNextStatus(_ status: CKAccountStatus) {
        nextStatus = .success(status)
    }

    func setNextFailure(_ error: Error) {
        nextStatus = .failure(error)
    }
}

// MARK: - publishingState classifier (CV-6)

@Test func onlyAvailableIsReady() {
    #expect(AccountStatusMonitor.publishingState(for: .available) == .ready)
}

@Test(arguments: [CKAccountStatus.noAccount, .temporarilyUnavailable, .restricted, .couldNotDetermine])
func everyNonAvailableStatusIsBlocked(_ status: CKAccountStatus) {
    #expect(AccountStatusMonitor.publishingState(for: status) == .blocked(status))
}

// MARK: - refresh / start behavior

@Test func startFetchesOnceAndReportsStatus() async {
    let source = MockAccountStatusSource()
    await source.setNextStatus(.available)
    let reported = ReportedStatuses()

    let center = NotificationCenter()
    let monitor = AccountStatusMonitor(source: source, notificationCenter: center) { status in
        Task { await reported.append(status) }
    }
    await monitor.start()
    #expect(await eventually { await reported.values == [.available] })

    #expect(await monitor.lastKnownStatus == .available)
    #expect(await source.callCount == 1)
}

@Test func refreshOnTransientErrorLeavesLastKnownStatusUnchangedAndDoesNotReport() async {
    let source = MockAccountStatusSource()
    await source.setNextStatus(.available)
    let reported = ReportedStatuses()
    let center = NotificationCenter()
    let monitor = AccountStatusMonitor(source: source, notificationCenter: center) { status in
        Task { await reported.append(status) }
    }
    await monitor.start()
    #expect(await eventually { await reported.values == [.available] })

    await source.setNextFailure(CKError(.networkUnavailable))
    await monitor.refresh()

    // `refresh()` is awaited, so the failed fetch is already handled; the only
    // asynchronous tail left would be a spurious onChange hop. Absence can't be
    // polled for, so settle briefly and then assert nothing arrived. If this
    // window is ever too short the test under-reports a real bug — it does not
    // fail spuriously, which is the tradeoff worth taking in a release gate.
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(await monitor.lastKnownStatus == .available)  // unchanged, not silently "blocked" or reset
    #expect(await reported.values == [.available])  // no spurious onChange for the failed refresh
}

@Test func accountChangedNotificationTriggersARefresh() async {
    let source = MockAccountStatusSource()
    await source.setNextStatus(.noAccount)
    let reported = ReportedStatuses()
    let center = NotificationCenter()
    let monitor = AccountStatusMonitor(source: source, notificationCenter: center) { status in
        Task { await reported.append(status) }
    }
    await monitor.start()
    #expect(await eventually { await monitor.lastKnownStatus == .noAccount })

    await source.setNextStatus(.available)
    center.post(name: .CKAccountChanged, object: nil)
    // The observer loop, the refresh, and the onChange Task all have to run.
    #expect(await eventually { await monitor.lastKnownStatus == .available })

    #expect(await source.callCount == 2)
    await monitor.stopObserving()
}

/// Regression: `start()` must not return until the observer is actually
/// registered.
///
/// The original implementation spawned `Task { for await _ in
/// NotificationCenter.default.notifications(...) }`, which returns as soon as
/// the Task is *created* — the sequence does not subscribe until the child task
/// first iterates. A notification posted in that window was dropped. Posting
/// with no intervening await is the only way to exercise it: every existing
/// test slept first, which is exactly why the race survived.
@Test func notificationPostedImmediatelyAfterStartIsNotDropped() async {
    let source = MockAccountStatusSource()
    await source.setNextStatus(.noAccount)
    let center = NotificationCenter()
    let monitor = AccountStatusMonitor(source: source, notificationCenter: center) { _ in }

    await monitor.start()
    await source.setNextStatus(.available)
    center.post(name: .CKAccountChanged, object: nil)  // no sleep: the point of the test

    #expect(await eventually { await monitor.lastKnownStatus == .available })
    #expect(await source.callCount == 2)
    await monitor.stopObserving()
}

/// Polls `condition` until it holds or `timeout` elapses; reports whether it held.
///
/// `AccountStatusMonitor` reports through `onChange`, which these tests hop onto
/// a detached `Task` — there is no handle to await. The original tests slept a
/// fixed 10ms instead, betting that the scheduler would run that Task promptly.
/// On a loaded machine it does not: the suite failed ~1 run in 12 under CPU
/// contention (found 2026-08-05 while wiring this package into `test-gate.sh`).
/// Polling leaves the passing path just as fast — the first check almost always
/// succeeds — while removing the race, so a busy gate machine can't turn green
/// code red.
private func eventually(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    repeat {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    } while ContinuousClock.now < deadline
    return await condition()
}

private actor ReportedStatuses {
    private(set) var values: [CKAccountStatus] = []
    func append(_ status: CKAccountStatus) {
        values.append(status)
    }
}
