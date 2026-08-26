import Foundation
import GradusKit
@testable import GradusMac
import Testing

/// Covers the last-successful-sync timestamp behind the menu's status line.
///
/// Every case runs against a scratch `UserDefaults` suite rather than
/// `.standard`. This bundle is hosted, so `.standard` in a test *is*
/// GradusMac's own preference domain — a test writing there leaves the real
/// menu reporting a sync that never happened. That is not theoretical: adding
/// persistence to `cloudSyncDidSucceed` immediately caused a pre-existing test
/// in `GradusMacTests.swift` to stamp a live timestamp into the shipping app's
/// preferences, which is what motivated injecting the store at all.
@MainActor
@Suite("Sync timestamp")
struct SyncTimestampTests {
    private func withScratchDefaults(_ name: String, _ body: (UserDefaults) -> Void) {
        let suite = "com.zerodelta.gradus.mac.tests.\(name)"
        guard let defaults = scratchDefaults(suite) else {
            Issue.record("could not create scratch defaults suite \(suite)")
            return
        }
        defer { removeScratchDefaultsSuite(suite, using: defaults) }
        body(defaults)
    }

    private let stamp = Date(timeIntervalSince1970: 1_785_960_000)

    @Test func successRecordsAndPersistsTheTimestamp() {
        withScratchDefaults("success") { defaults in
            let viewModel = PublisherViewModel(defaults: defaults)
            viewModel.syncEnabled = true
            guard let id = viewModel.cloudSyncDidStart() else {
                Issue.record("sync did not start despite being enabled")
                return
            }
            viewModel.cloudSyncDidSucceed(operationID: id, at: stamp)

            #expect(viewModel.lastSyncedAt == stamp)
            #expect(viewModel.syncState == .synced)
            #expect(
                defaults.object(forKey: PublisherViewModel.lastSyncedAtKey) as? Double
                    == stamp.timeIntervalSince1970
            )
            // A relaunch must recover it: the state enum resets, the stamp
            // must not.
            let relaunched = PublisherViewModel(defaults: defaults)
            #expect(relaunched.lastSyncedAt == stamp)
            #expect(relaunched.syncState == .idle)
        }
    }

    @Test func neverSyncedReadsAsNilRatherThanTheEpoch() {
        withScratchDefaults("never") { defaults in
            #expect(PublisherViewModel(defaults: defaults).lastSyncedAt == nil)
        }
    }

    /// A late callback from a superseded operation must not backdate the
    /// timestamp -- that would report staleness that never happened.
    @Test func staleOperationDoesNotRecordATimestamp() {
        withScratchDefaults("stale") { defaults in
            let viewModel = PublisherViewModel(defaults: defaults)
            viewModel.syncEnabled = true
            guard let first = viewModel.cloudSyncDidStart() else { return }
            _ = viewModel.cloudSyncDidStart() // supersedes `first`
            viewModel.cloudSyncDidSucceed(operationID: first, at: stamp)
            #expect(viewModel.lastSyncedAt == nil)
        }
    }

    @Test func failureLeavesThePriorTimestampIntact() {
        withScratchDefaults("failure") { defaults in
            let viewModel = PublisherViewModel(defaults: defaults)
            viewModel.syncEnabled = true
            guard let ok = viewModel.cloudSyncDidStart() else { return }
            viewModel.cloudSyncDidSucceed(operationID: ok, at: stamp)
            guard let bad = viewModel.cloudSyncDidStart() else { return }
            viewModel.cloudSyncDidFail(operationID: bad)

            #expect(viewModel.syncState == .failed)
            #expect(viewModel.lastSyncedAt == stamp, "a failure must not erase the last good sync")
        }
    }

    // MARK: - Label

    @Test func labelIsNilWhenNeverSynced() {
        #expect(MenuContentView.lastSyncLabel(nil) == nil)
    }

    /// Must use the same vocabulary as the "resets …" copy on each row, so the
    /// menu never shows two date formats at once.
    @Test func labelMatchesTheRowDateVocabulary() {
        let now = Date(timeIntervalSince1970: 1_785_960_000)
        let label = MenuContentView.lastSyncLabel(now, now: now)
        #expect(label == "Last sync \(friendlyDateLabel(now, now: now))")
        #expect(label?.contains("Today") == true)
    }
}

@Test func requiredICloudMigrationMatchesIOSForLegacyAndFreshStores() throws {
    let falseSuite = "com.zerodelta.gradus.mac.tests.required-icloud-false"
    let falseDefaults = try #require(scratchDefaults(falseSuite))
    defer { removeScratchDefaultsSuite(falseSuite, using: falseDefaults) }
    falseDefaults.set(false, forKey: PublisherViewModel.syncEnabledKey)
    #expect(
        RequiredICloudMigration.migrate(defaults: falseDefaults, legacyKey: PublisherViewModel.syncEnabledKey)
            == .awaitingConfirmation
    )
    #expect(falseDefaults.object(forKey: PublisherViewModel.syncEnabledKey) == nil)

    let trueSuite = "com.zerodelta.gradus.mac.tests.required-icloud-true"
    let trueDefaults = try #require(scratchDefaults(trueSuite))
    defer { removeScratchDefaultsSuite(trueSuite, using: trueDefaults) }
    trueDefaults.set(true, forKey: PublisherViewModel.syncEnabledKey)
    #expect(
        RequiredICloudMigration.migrate(defaults: trueDefaults, legacyKey: PublisherViewModel.syncEnabledKey)
            == .confirmed
    )

    let freshSuite = "com.zerodelta.gradus.mac.tests.required-icloud-fresh"
    let freshDefaults = try #require(scratchDefaults(freshSuite))
    defer { removeScratchDefaultsSuite(freshSuite, using: freshDefaults) }
    #expect(
        RequiredICloudMigration.migrate(defaults: freshDefaults, legacyKey: PublisherViewModel.syncEnabledKey)
            == .confirmed
    )
}

@Test func requiredICloudMigrationNewModeWinsAndInterruptedWriteReruns() throws {
    let suite = "com.zerodelta.gradus.mac.tests.required-icloud-both"
    let defaults = try #require(scratchDefaults(suite))
    defer { removeScratchDefaultsSuite(suite, using: defaults) }
    defaults.set(true, forKey: PublisherViewModel.syncEnabledKey)
    defaults.set(RequiredICloudMode.awaitingConfirmation.rawValue, forKey: RequiredICloudMigration.modeKey)
    #expect(
        RequiredICloudMigration.migrate(defaults: defaults, legacyKey: PublisherViewModel.syncEnabledKey)
            == .awaitingConfirmation
    )

    let interruptedSuite = "com.zerodelta.gradus.mac.tests.required-icloud-interrupted"
    let interrupted = try #require(scratchDefaults(interruptedSuite))
    defer { removeScratchDefaultsSuite(interruptedSuite, using: interrupted) }
    interrupted.set(false, forKey: PublisherViewModel.syncEnabledKey)
    #expect(
        RequiredICloudMigration.migrate(
            defaults: interrupted, legacyKey: PublisherViewModel.syncEnabledKey, writeMode: { _, _ in }
        )
            == .awaitingConfirmation
    )
    #expect(interrupted.object(forKey: PublisherViewModel.syncEnabledKey) != nil)
    #expect(interrupted.object(forKey: RequiredICloudMigration.modeKey) == nil)
    #expect(
        RequiredICloudMigration.migrate(defaults: interrupted, legacyKey: PublisherViewModel.syncEnabledKey)
            == .awaitingConfirmation
    )
    #expect(interrupted.object(forKey: PublisherViewModel.syncEnabledKey) == nil)
}

@Test @MainActor func requiredICloudModeConfirmsAndSurvivesRelaunch() throws {
    let suite = "com.zerodelta.gradus.mac.tests.required-icloud-relaunch"
    let defaults = try #require(scratchDefaults(suite))
    defer { removeScratchDefaultsSuite(suite, using: defaults) }
    defaults.set(false, forKey: PublisherViewModel.syncEnabledKey)

    let awaiting = PublisherViewModel(defaults: defaults)
    #expect(awaiting.requiredICloudMode == .awaitingConfirmation)
    #expect(!awaiting.syncEnabled)
    awaiting.confirmRequiredICloud()

    let relaunched = PublisherViewModel(defaults: defaults)
    #expect(relaunched.requiredICloudMode == .confirmed)
    #expect(relaunched.syncEnabled)
    #expect(defaults.object(forKey: PublisherViewModel.syncEnabledKey) == nil)
    #expect(
        defaults.integer(forKey: PublisherViewModel.requiredICloudModeVersionKey)
            == PublisherViewModel.requiredICloudModeVersion
    )
}
