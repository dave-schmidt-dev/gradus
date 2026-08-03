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

    let monitor = AccountStatusMonitor(source: source) { status in
        Task { await reported.append(status) }
    }
    await monitor.start()
    // Allow the detached onChange Task to run.
    try? await Task.sleep(nanoseconds: 10_000_000)

    #expect(await monitor.lastKnownStatus == .available)
    #expect(await source.callCount == 1)
    #expect(await reported.values == [.available])
}

@Test func refreshOnTransientErrorLeavesLastKnownStatusUnchangedAndDoesNotReport() async {
    let source = MockAccountStatusSource()
    await source.setNextStatus(.available)
    let reported = ReportedStatuses()
    let monitor = AccountStatusMonitor(source: source) { status in
        Task { await reported.append(status) }
    }
    await monitor.start()
    try? await Task.sleep(nanoseconds: 10_000_000)

    await source.setNextFailure(CKError(.networkUnavailable))
    await monitor.refresh()

    #expect(await monitor.lastKnownStatus == .available)  // unchanged, not silently "blocked" or reset
    #expect(await reported.values == [.available])  // no spurious onChange for the failed refresh
}

@Test func accountChangedNotificationTriggersARefresh() async {
    let source = MockAccountStatusSource()
    await source.setNextStatus(.noAccount)
    let reported = ReportedStatuses()
    let monitor = AccountStatusMonitor(source: source) { status in
        Task { await reported.append(status) }
    }
    await monitor.start()
    try? await Task.sleep(nanoseconds: 10_000_000)
    #expect(await monitor.lastKnownStatus == .noAccount)

    await source.setNextStatus(.available)
    NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
    // The observer loop + refresh + onChange Task all need a moment.
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(await monitor.lastKnownStatus == .available)
    #expect(await source.callCount == 2)
    await monitor.stopObserving()
}

private actor ReportedStatuses {
    private(set) var values: [CKAccountStatus] = []
    func append(_ status: CKAccountStatus) {
        values.append(status)
    }
}
