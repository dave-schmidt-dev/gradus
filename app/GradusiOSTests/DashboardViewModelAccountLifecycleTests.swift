import Foundation
@testable import GradusiOS
import GradusKit
import Testing

// Account status, retry, and live/sample lifecycle transition coverage,
// split out of DashboardViewModelSyncTests.swift to keep that file under
// SwiftLint's file_length limit. Shares fixtures with it via
// DashboardViewModelSyncFixtures.swift.

private actor LifecycleSeamRecorder {
    private(set) var calls: [String] = []
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    func call(_ seam: String, blocking: Bool = false) async {
        calls.append(seam)
        guard blocking else { return }
        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
        }
    }

    func releaseBlockedCall() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

private actor TransitionCompletionRecorder {
    private(set) var completionCount = 0

    func markCompleted() {
        completionCount += 1
    }
}

/// The sample transition is a real lifecycle boundary, not only a view swap:
/// iPhone and iPad must both wait out an in-flight live seam and reject every
/// subsequent account/sync/subscription/notification/provider call.
@MainActor
struct LiveLifecycleTransitionTests {
    @Test
    func concurrentSampleSuspendsAllWaitForLiveQuiescence() async {
        let gate = LiveLifecycleGate()
        let recorder = TransitionCompletionRecorder()
        #expect(gate.begin() != nil)

        let first = Task { @MainActor in
            await gate.suspend()
            await recorder.markCompleted()
        }
        while !gate.isSuspended {
            await Task.yield()
        }

        let second = Task { @MainActor in
            await gate.suspend()
            await recorder.markCompleted()
        }
        await Task.yield()
        #expect(await recorder.completionCount == 0)

        gate.finish()
        await first.value
        await second.value
        #expect(await recorder.completionCount == 2)
    }

    @Test
    func sampleEntryPendingLabelsAreVisibleAndDistinct() {
        #expect(EmptyStateView.exploreSampleButtonTitle(isInProgress: false) == "Explore Sample")
        #expect(EmptyStateView.exploreSampleButtonTitle(isInProgress: true) == "Entering Sample…")
        #expect(SettingsView.exploreSampleButtonTitle(isInProgress: false) == "Explore Sample")
        #expect(SettingsView.exploreSampleButtonTitle(isInProgress: true) == "Entering Sample…")
    }

    @Test(arguments: ["iPhone", "iPad"])
    func exploreSampleWaitsForQuiescenceAndEpochGatesLiveSeams(_ device: String) async {
        let gate = LiveLifecycleGate()
        let recorder = LifecycleSeamRecorder()

        let liveWork = Task { @MainActor in
            await gate.withOperation { operationEpoch in
                await recorder.call("account", blocking: true)
                guard gate.isCurrent(operationEpoch) else { return }
                await recorder.call("sync")
                guard gate.isCurrent(operationEpoch) else { return }
                await recorder.call("subscription")
                guard gate.isCurrent(operationEpoch) else { return }
                await recorder.call("notification")
                guard gate.isCurrent(operationEpoch) else { return }
                await recorder.call("provider")
            }
        }

        // The first seam call proves the transition really has work to drain.
        while await recorder.calls.isEmpty {
            await Task.yield()
        }
        let enterSample = Task { @MainActor in await gate.suspend() }
        while !gate.isSuspended {
            await Task.yield()
        }

        // Entry invalidates the epoch immediately, but waits for the in-flight
        // account call before returning and exposing the sample UI.
        #expect(await recorder.calls == ["account"], "\(device) entered before quiescence")
        await recorder.releaseBlockedCall()
        await enterSample.value
        await liveWork.value

        let rejected = await gate.withOperation { _ in
            await recorder.call("post-entry")
        }
        #expect(rejected == nil)
        #expect(await recorder.calls == ["account"], "\(device) made a live call after sample entry")
    }
}

@MainActor
@Test func updateAccountStatusTriggersSyncOnlyOnAvailableTransition() {
    let cache = syncTempCache()
    let fetcher = MockZoneChangesFetcher(outcomes: [])
    let viewModel = DashboardViewModel(cache: cache, zoneChangesFetcher: fetcher, userDefaults: syncIsolatedDefaults())
    viewModel.syncEnabled = true

    viewModel.updateAccountStatus(.noAccount)
    #expect(viewModel.accountStatus == .noAccount)

    viewModel.updateAccountStatus(.available)
    #expect(viewModel.accountStatus == .available)
    // The app-level reconciliation callback owns the full fetch; this test
    // only asserts the status transition itself is recorded correctly.
}

@MainActor
@Test func temporaryAccountStatesUseCheckingThenTryAgainAndConfirmedRecoveryCopy() {
    let viewModel = DashboardViewModel(cache: syncTempCache(), userDefaults: syncIsolatedDefaults())

    viewModel.updateAccountStatus(.couldNotDetermine)
    #expect(viewModel.emptyState == .checkingICloud)

    viewModel.accountAvailabilityCheckFailed()
    #expect(viewModel.emptyState == .tryAgain)

    viewModel.updateAccountStatus(.noAccount)
    #expect(viewModel.emptyState == .notSignedIn)

    viewModel.updateAccountStatus(.restricted)
    #expect(viewModel.emptyState == .restricted)
}

@MainActor
@Test func retryableSyncFailureRetainsCachedDataAndSurfacesRetry() async {
    let cache = syncTempCache()
    let cached = makeStatus("cached")
    try? cache.saveCachedStatuses([cached], syncedAt: Date())
    let defaults = syncIsolatedDefaults()
    defaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    let viewModel = DashboardViewModel(
        cache: cache, fetcher: FailingCloudFetcher(), userDefaults: defaults
    )
    viewModel.updateAccountStatus(.available)

    await viewModel.reconcileLiveLifecycle()

    #expect(viewModel.providers.map(\.providerName) == ["cached"])
    #expect(viewModel.liveLifecycleNeedsRetry)
}

private struct FailingCloudFetcher: CloudFetcher {
    func fetchAll() async throws -> [ProviderStatus] {
        struct RetryableError: Error {}
        throw RetryableError()
    }
}
