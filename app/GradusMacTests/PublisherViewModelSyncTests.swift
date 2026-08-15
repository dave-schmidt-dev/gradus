import Foundation
import GradusKit
@testable import GradusMac
import Testing

// MARK: - Cloud sync state machine

@Test @MainActor func cloudSyncFailureIsVisibleAndClearsWhenDisabled() throws {
    // Scratch suite: this bundle is hosted, so `.standard` is the shipping
    // app's own preference domain. Isolating the store keeps a test from
    // writing state the real menu then reports as fact.
    let suite = "com.zerodelta.gradus.mac.tests.cloudSyncFailure"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let viewModel = PublisherViewModel(defaults: defaults)
    viewModel.syncEnabled = true
    let operationID = try #require(viewModel.cloudSyncDidStart())
    #expect(viewModel.syncState == .publishing)
    viewModel.cloudSyncDidFail(operationID: operationID)
    #expect(viewModel.syncState == .failed)
    viewModel.syncEnabled = false
    #expect(viewModel.syncState == .idle)
}

@Test @MainActor func staleCloudSyncCompletionsCannotOverwriteCurrentOrDisabledState() throws {
    // Scratch suite rather than save/restore against `.standard`. This bundle
    // is hosted, so `.standard` is the shipping app's own preference domain --
    // and the save/restore this replaced only covered `syncEnabledKey`, so the
    // moment `cloudSyncDidSucceed` began persisting a timestamp, this test
    // started stamping a live `Date()` into the real menu's state. Isolating
    // the store removes the whole class instead of adding a second key to a
    // list someone has to remember to extend.
    let suite = "com.zerodelta.gradus.mac.tests.staleCloudSync"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let viewModel = PublisherViewModel(defaults: defaults)
    viewModel.syncEnabled = true
    let olderOperation = try #require(viewModel.cloudSyncDidStart())
    let currentOperation = try #require(viewModel.cloudSyncDidStart())

    viewModel.cloudSyncDidFail(operationID: olderOperation)
    #expect(viewModel.syncState == .publishing)
    viewModel.cloudSyncDidSucceed(operationID: currentOperation)
    #expect(viewModel.syncState == .synced)

    let disabledOperation = try #require(viewModel.cloudSyncDidStart())
    viewModel.syncEnabled = false
    viewModel.cloudSyncDidFail(operationID: disabledOperation)
    #expect(viewModel.syncState == .idle)
}

@Test @MainActor func cloudSyncCannotStartAfterSyncWasDisabled() throws {
    // Scratch suite: this bundle is hosted, so `.standard` is the shipping
    // app's own preference domain. Isolating the store keeps a test from
    // writing state the real menu then reports as fact.
    let suite = "com.zerodelta.gradus.mac.tests.syncDisabled"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let viewModel = PublisherViewModel(defaults: defaults)
    viewModel.syncEnabled = false

    #expect(viewModel.cloudSyncDidStart() == nil)
    #expect(viewModel.syncState == .idle)
}
