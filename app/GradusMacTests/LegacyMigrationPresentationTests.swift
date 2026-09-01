import Foundation
@testable import GradusMac
import Testing

/// What Settings is allowed to say about the legacy job, and what it may offer
/// the user to do about it.
@Suite("Legacy migration presentation")
@MainActor
struct LegacyMigrationPresentationTests {
    /// `suite` is the caller's scope: `scratchDefaults` clears the domain on
    /// entry, so two tests sharing a name would wipe each other mid-run.
    private func viewModel(
        _ migrator: LegacyRuntimeMigrator?, wrapper: URL, suite: String
    ) -> PublisherViewModel {
        PublisherViewModel(
            defaults: scratchDefaults("com.zerodelta.gradus.mac.migration.\(suite)")!,
            legacyMigrator: migrator,
            legacyWrapperURL: wrapper,
            legacyBridgeURL: URL(fileURLWithPath: "/nonexistent/GradusCredentialBridge.app")
        )
    }

    @Test func aMacWithNoLegacyRuntimeShowsNothing() {
        let fixture = MigrationFixture("presentation-none")
        defer { fixture.cleanUp() }
        let model = viewModel(
            makeMigrator(fixture, job: FakeLegacyJob(state: .absent)),
            wrapper: fixture.root.appendingPathComponent("absent.sh"),
            suite: "presentation-none"
        )

        model.refreshLegacyMigration()

        #expect(model.legacyMigration == .notApplicable)
        #expect(!model.legacyMigration.canStartMigration)
    }

    @Test func aMissingMigratorIsNotApplicableRatherThanEmpty() {
        let fixture = MigrationFixture("presentation-nil")
        defer { fixture.cleanUp() }
        let model = viewModel(nil, wrapper: fixture.root, suite: "presentation-nil")

        model.refreshLegacyMigration()

        #expect(model.legacyMigration == .notApplicable)
    }

    @Test func aBlockedGateNamesTheConsumersAndOffersNoButton() throws {
        let fixture = MigrationFixture("presentation-blocked")
        defer { fixture.cleanUp() }
        let wrapper = fixture.root.appendingPathComponent("gradus_snapshot.sh")
        try Data("legacy".utf8).write(to: wrapper)
        let model = viewModel(
            makeMigrator(fixture, job: FakeLegacyJob(state: .loaded(enabled: true))),
            wrapper: wrapper,
            suite: "presentation-blocked"
        )

        model.refreshLegacyMigration()

        #expect(model.legacyMigration == .waitingOnConsumers([
            .missing(consumer: "hermes-publisher"), .missing(consumer: "review-plugin")
        ]))
        #expect(!model.legacyMigration.canStartMigration)
        #expect(model.legacyMigration.explanation.contains("still running"))
    }

    @Test func aClearedGateOffersTheMigrationExactlyOnce() throws {
        let fixture = MigrationFixture("presentation-ready")
        defer { fixture.cleanUp() }
        fixture.writeAllReceipts()
        let wrapper = fixture.root.appendingPathComponent("gradus_snapshot.sh")
        try Data("legacy".utf8).write(to: wrapper)
        let model = viewModel(
            makeMigrator(fixture, job: FakeLegacyJob(state: .loaded(enabled: true))),
            wrapper: wrapper,
            suite: "presentation-ready"
        )

        model.refreshLegacyMigration()
        #expect(model.legacyMigration == .ready)
        #expect(model.legacyMigration.canStartMigration)

        model.startLegacyMigration()
        // Already running: a second click must not start a second cutover.
        #expect(!model.legacyMigration.canStartMigration)
        model.refreshLegacyMigration()
        if case .running = model.legacyMigration {} else {
            Issue.record("a refresh during a migration overwrote its progress")
        }
    }

    /// Every rendered state answers "is anything of mine at risk?" without a
    /// path, a command, or a provider payload in it.
    @Test func everyPresentationHasSafeCopy() {
        let states: [LegacyMigrationPresentation] = [
            .notApplicable,
            .waitingOnConsumers([.stale(consumer: "review-plugin")]),
            .ready,
            .running(LegacyMigrationPhase.stoppingLegacy.progressDescription),
            .migrated,
            .rolledBack(.noFreshSnapshots)
        ]
        for state in states {
            #expect(!state.headline.isEmpty)
            #expect(!state.explanation.isEmpty)
            #expect(!state.explanation.contains("/"))
        }
        #expect(LegacyMigrationPresentation.migrated.explanation.contains("not deleted"))
        #expect(LegacyMigrationPresentation.rolledBack(.noFreshSnapshots)
            .explanation.contains("nothing was deleted"))
    }
}
