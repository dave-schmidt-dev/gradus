import AppKit
import Foundation
import GradusKit
import Testing

@testable import GradusMac

/// Covers the Mac's three local display preferences — sort order, warning
/// threshold, and exhausted-provider visibility — which exist to match iOS's
/// Settings screen rather than to configure anything about publishing.
///
/// Scratch `UserDefaults` throughout, for the reason spelled out in
/// `SyncTimestampTests`: this bundle is hosted, so `.standard` in a test is the
/// shipping app's own preference domain. A test that flipped `showExhausted`
/// against `.standard` would leave providers missing from the real menu.
@MainActor
@Suite("Display preferences")
struct DisplayPreferenceTests {
    private func withScratchDefaults(_ name: String, _ body: (UserDefaults) -> Void) {
        let suite = "com.zerodelta.gradus.mac.tests.display.\(name)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create scratch defaults suite \(suite)")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    private func provider(_ name: String, percentLeft: Double) -> ProviderEntry {
        ProviderEntry(
            name: name,
            ok: true,
            error: nil,
            windows: [
                ProviderWindow(
                    id: "weekly",
                    percentLeft: percentLeft,
                    resetISO: "2026-08-09T00:00:00Z",
                    windowHours: 168,
                    paceDelta: nil
                )
            ],
            data: [:],
            observedAt: nil
        )
    }

    /// The defaults matter as much as the persistence. Both stores return a
    /// falsy zero for a missing key, so a fresh install reading them without a
    /// presence check would hide exhausted providers and warn about nothing —
    /// while looking, from the outside, exactly like a deliberate choice.
    @Test func freshInstallShowsExhaustedAndWarnsAtTheSameThresholdAsIOS() {
        withScratchDefaults("fresh") { defaults in
            let viewModel = PublisherViewModel(defaults: defaults)

            #expect(viewModel.showExhausted)
            #expect(viewModel.providerSortOption == .mostUrgent)
            #expect(viewModel.localWarningThresholdPercent == 20.0)
            #expect(
                viewModel.localWarningThresholdPercent
                    == PublisherViewModel.defaultLocalWarningThresholdPercent
            )
        }
    }

    @Test func allThreePreferencesSurviveRelaunch() {
        withScratchDefaults("persist") { defaults in
            let viewModel = PublisherViewModel(defaults: defaults)
            viewModel.showExhausted = false
            viewModel.providerSortOption = .nameAZ
            viewModel.localWarningThresholdPercent = 35

            let relaunched = PublisherViewModel(defaults: defaults)
            #expect(!relaunched.showExhausted)
            #expect(relaunched.providerSortOption == .nameAZ)
            #expect(relaunched.localWarningThresholdPercent == 35)
        }
    }

    /// Zero is the value the presence check exists to protect, so it gets its
    /// own case: "warn me about nothing" must round-trip as a real setting and
    /// not be mistaken for an unset key on the next launch.
    @Test func anExplicitZeroThresholdIsNotMistakenForUnset() {
        withScratchDefaults("zero") { defaults in
            let viewModel = PublisherViewModel(defaults: defaults)
            viewModel.localWarningThresholdPercent = 0

            #expect(PublisherViewModel(defaults: defaults).localWarningThresholdPercent == 0)
        }
    }

    @Test func showExhaustedFiltersDepletedProvidersOutOfTheMenu() {
        withScratchDefaults("filter") { defaults in
            let viewModel = PublisherViewModel(defaults: defaults)
            viewModel.apply(
                SnapshotPayload(
                    schemaVersion: 2,
                    updatedAt: "2026-08-05T12:00:00Z",
                    providers: [
                        provider("Codex", percentLeft: 62),
                        provider("Copilot", percentLeft: 0),
                    ]
                )
            )
            let menu = MenuContentView(viewModel: viewModel)

            #expect(menu.visibleProviders.map(\.name) == ["Codex", "Copilot"])

            viewModel.showExhausted = false
            #expect(menu.visibleProviders.map(\.name) == ["Codex"])
        }
    }

    /// Hiding is a display choice, not a data one: the provider is still in the
    /// view model, so the publish path and the menu bar icon — which read the
    /// payload, not this filtered list — are unaffected.
    @Test func hidingExhaustedDoesNotRemoveProvidersFromTheViewModel() {
        withScratchDefaults("nondestructive") { defaults in
            let viewModel = PublisherViewModel(defaults: defaults)
            viewModel.apply(
                SnapshotPayload(
                    schemaVersion: 2,
                    updatedAt: "2026-08-05T12:00:00Z",
                    providers: [provider("Copilot", percentLeft: 0)]
                )
            )
            viewModel.showExhausted = false

            #expect(viewModel.providers.map(\.name) == ["Copilot"])
            #expect(MenuContentView(viewModel: viewModel).visibleProviders.isEmpty)
        }
    }
}

/// The gate for the Settings window itself.
///
/// Its predecessor — a `Settings` scene opened with
/// `NSApp.sendAction(Selector(("showSettingsWindow:")))` — shipped broken and
/// could not have been caught by any assertion about the *action*:
/// `sendAction` returned `true`, and the responder resolved even with the
/// scene deleted entirely. The only honest question is whether a window
/// exists afterward, so that is what this asks.
///
/// Every case goes through `makeWindow` rather than `show`. This bundle is
/// hosted, so a `show` here would activate the app and drop a settings window
/// over the work of whoever is at the machine on every gate run — a test suite
/// that interrupts you is one you learn to stop running. Nothing is given up:
/// the defects worth catching are construction defects, and both of the ones
/// this suite has already caught were.
@MainActor
@Suite("Settings window")
struct SettingsWindowTests {
    private func scratchViewModel() -> PublisherViewModel {
        PublisherViewModel(
            defaults: UserDefaults(suiteName: "com.zerodelta.gradus.mac.tests.settingswindow")!
        )
    }

    @Test func settingsProducesAWindowTheAppOwnsAndCanActuallyBeReadIn() {
        SettingsWindow.resetForTesting()
        defer { SettingsWindow.resetForTesting() }

        let window = SettingsWindow.makeWindow(viewModel: scratchViewModel())

        // The assertion the old `Settings` scene could never have passed: an
        // `NSWindow` exists and the app owns it.
        #expect(NSApp.windows.contains(window))
        #expect(window.title == SettingsWindow.title)
        // A hosting controller that fails to measure its SwiftUI content
        // yields a zero- or near-zero-sized window, which is a window and is
        // still useless. `MacSettingsView` fixes width at 420 and lets height
        // follow the form.
        #expect(window.frame.width >= 400)
        #expect(window.frame.height > 200)
    }

    @Test func repeatedRequestsReuseTheSameWindow() {
        SettingsWindow.resetForTesting()
        defer { SettingsWindow.resetForTesting() }
        let viewModel = scratchViewModel()

        let first = SettingsWindow.makeWindow(viewModel: viewModel)
        let second = SettingsWindow.makeWindow(viewModel: viewModel)

        // Identity, not a count of settings windows in `NSApp.windows`: a
        // closed window lingers in that array until it deallocates, so the
        // count picks up other cases' windows and says nothing about this one.
        // Identity is the actual property — a second click re-focuses the
        // window you have instead of stacking another copy on it.
        #expect(first === second)
    }

    /// `isReleasedWhenClosed` defaults to true for programmatically-created
    /// windows, which would deallocate the cached window on close and leave
    /// `SettingsWindow` holding a dangling reference to reopen from. Asserted
    /// on the flag directly — the dangling case is undefined behavior, so
    /// there's nothing to observe once it's wrong; the reopen below covers the
    /// other half, that closing doesn't drop the cache.
    @Test func aClosedWindowIsKeptAroundToBeReopened() {
        SettingsWindow.resetForTesting()
        defer { SettingsWindow.resetForTesting() }
        let viewModel = scratchViewModel()

        let first = SettingsWindow.makeWindow(viewModel: viewModel)
        #expect(!first.isReleasedWhenClosed)
        first.close()

        let reopened = SettingsWindow.makeWindow(viewModel: viewModel)
        #expect(reopened === first)
        #expect(reopened.frame.width >= 400)
    }
}
