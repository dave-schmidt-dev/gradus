import Foundation
import GradusKit
@testable import GradusMac
import Testing

@MainActor
@Suite("MenuBarBucketTests")
struct MenuBarBucketTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-07T16:00:00Z")!

    private func provider(
        _ name: String = "Codex",
        ok: Bool = true,
        error: String? = nil,
        id: String = "weekly",
        percent: Double = 31
    ) -> ProviderEntry {
        ProviderEntry(
            name: name,
            ok: ok,
            error: error,
            windows: [
                ProviderWindow(
                    id: id,
                    percentLeft: percent,
                    resetISO: nil,
                    windowHours: 168,
                    paceDelta: nil
                )
            ],
            data: [:],
            observedAt: "2026-09-07T15:59:00Z"
        )
    }

    private func payload(
        _ providers: [ProviderEntry],
        updatedAt: String = "2026-09-07T15:59:00.123Z"
    ) -> SnapshotPayload {
        SnapshotPayload(schemaVersion: supportedSchemaVersion, updatedAt: updatedAt, providers: providers)
    }

    private func withDefaults(_ name: String, _ body: (UserDefaults) -> Void) {
        let suite = "com.zerodelta.gradus.mac.tests.bucket.\(name)"
        guard let defaults = scratchDefaults(suite) else {
            Issue.record("could not create scratch defaults suite \(suite)")
            return
        }
        defer { removeScratchDefaultsSuite(suite, using: defaults) }
        body(defaults)
    }

    @Test func freshInstallUsesGaugeAndSelectionPersistsAcrossRelaunch() {
        withDefaults("persistence") { defaults in
            let viewModel = PublisherViewModel(defaults: defaults)
            #expect(viewModel.menuBarDisplaySelection == .gauge)

            viewModel.menuBarDisplaySelection = .bucket(providerName: "Codex", windowID: "weekly")
            #expect(
                PublisherViewModel(defaults: defaults).menuBarDisplaySelection
                    == .bucket(providerName: "Codex", windowID: "weekly")
            )
        }
    }

    @Test func codexWeeklyShowsFreshRemainingValueAndTracksSnapshotChanges() {
        withDefaults("updates") { defaults in
            let viewModel = PublisherViewModel(defaults: defaults)
            viewModel.menuBarDisplaySelection = .bucket(providerName: "Codex", windowID: "weekly")
            viewModel.apply(payload([provider(percent: 31)]))

            #expect(presentation(viewModel).title == "Codex W 31%")
            #expect(presentation(viewModel).accessibilityLabel == "Codex weekly, 31 percent remaining")

            viewModel.apply(payload([provider(percent: 27)]))
            #expect(presentation(viewModel).title == "Codex W 27%")
        }
    }

    @Test func identitiesRemainDistinctAndSurviveOrderingFilteringAndAbsence() {
        withDefaults("identity") { defaults in
            let viewModel = PublisherViewModel(defaults: defaults)
            let codex = provider("Codex", percent: 0)
            let other = provider("Claude", percent: 82)
            viewModel.apply(payload([other, codex]))

            let identities = Set(viewModel.menuBarBucketChoices.map(\.selection))
            #expect(identities.contains(.bucket(providerName: "Codex", windowID: "weekly")))
            #expect(identities.contains(.bucket(providerName: "Claude", windowID: "weekly")))

            viewModel.showExhausted = false
            viewModel.menuBarDisplaySelection = .bucket(providerName: "Codex", windowID: "weekly")
            let selected = viewModel.menuBarBucketChoices.first {
                $0.selection == viewModel.menuBarDisplaySelection
            }
            #expect(selected?.available == true)

            viewModel.apply(payload([other]))
            #expect(viewModel.menuBarBucketChoices.last?.selection == viewModel.menuBarDisplaySelection)
            #expect(viewModel.menuBarBucketChoices.last?.available == false)
            #expect(presentation(viewModel).title == "Codex W —")

            viewModel.apply(payload([codex, other]))
            #expect(viewModel.menuBarDisplaySelection == .bucket(providerName: "Codex", windowID: "weekly"))
            #expect(presentation(viewModel).title == "Codex W 0.0%")
        }
    }

    @Test func invalidMissingAndOrdinaryFailuresAreUnavailable() {
        let selection = MenuBarDisplaySelection.bucket(providerName: "Codex", windowID: "weekly")
        for providers in [
            [],
            [provider(percent: .nan)],
            [provider(percent: -.infinity)],
            [provider(percent: -0.1)],
            [provider(percent: 100.1)],
            [provider(ok: false, error: "probe failed", percent: 31)]
        ] {
            let result = MenuBarBucketPresenter.presentation(
                selection: selection,
                providers: providers,
                snapshotUpdatedAt: "2026-09-07T15:59:00Z",
                now: now
            )
            #expect(result.title == "Codex W —")
            #expect(result.accessibilityLabel.hasSuffix("unavailable"))
        }
    }

    @Test func boundaryValuesRemainValidAndAgedOrCarriedValuesAreMarkedStale() {
        let selection = MenuBarDisplaySelection.bucket(providerName: "Codex", windowID: "weekly")
        #expect(result(selection, [provider(percent: 0)], at: "2026-09-07T15:59:00Z").title == "Codex W 0.0%")
        #expect(result(selection, [provider(percent: 100)], at: "2026-09-07T15:59:00Z").title == "Codex W 100%")
        #expect(result(selection, [provider(percent: 31)], at: "2026-09-07T15:44:59Z").title == "Codex W 31%*")

        let carried = provider(
            ok: false,
            error: ProviderRetryAccessibility.copilotRetryLabel,
            percent: 31
        )
        let carriedResult = result(selection, [carried], at: "2026-09-07T15:59:00Z")
        #expect(carriedResult.title == "Codex W 31%*")
        #expect(carriedResult.accessibilityLabel.hasSuffix("stale"))
    }

    @Test func selectionAndLabelResolutionDoNotMutateSnapshotOrSyncState() {
        withDefaults("read-only") { defaults in
            let viewModel = PublisherViewModel(defaults: defaults)
            let snapshot = payload([provider(percent: 31)])
            viewModel.apply(snapshot)

            viewModel.menuBarDisplaySelection = .bucket(providerName: "Codex", windowID: "weekly")
            _ = presentation(viewModel)

            #expect(viewModel.providers == snapshot.providers)
            #expect(viewModel.updatedAt == snapshot.updatedAt)
            #expect(viewModel.syncState == .idle)
        }
    }

    private func presentation(_ viewModel: PublisherViewModel) -> MenuBarBucketPresentation {
        MenuBarBucketPresenter.presentation(
            selection: viewModel.menuBarDisplaySelection,
            providers: viewModel.providers,
            snapshotUpdatedAt: viewModel.updatedAt,
            now: now
        )
    }

    private func result(
        _ selection: MenuBarDisplaySelection,
        _ providers: [ProviderEntry],
        at updatedAt: String
    ) -> MenuBarBucketPresentation {
        MenuBarBucketPresenter.presentation(
            selection: selection,
            providers: providers,
            snapshotUpdatedAt: updatedAt,
            now: now
        )
    }
}
