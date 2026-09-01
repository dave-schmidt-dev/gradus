import AppKit
import GradusKit
import SwiftUI

/// The MenuBarExtra's dropdown content: one row per provider plus a settings
/// section (required-iCloud status, launch-at-login, quit). Renders entirely from
/// `PublisherViewModel`'s published state -- no direct CloudKit/file
/// dependency -- so it can be snapshot-tested standalone (T2b.1/T2b.4:
/// XCUITest can't drive a `LSUIElement` status item, so `swift-snapshot-
/// testing` against this view rendered offscreen is the gate instead).
///
/// **This view only renders as written when the scene uses
/// `.menuBarExtraStyle(.window)`.** Under the default `.menu` style SwiftUI
/// does not draw the view tree at all -- it translates it into `NSMenu`
/// items, which flattens every `HStack`, drops custom shapes (the bars
/// below), and replaces the ramp colors with menu text styling. That is not a
/// theoretical caveat: the bars and colors here shipped on 2026-08-05 and had
/// never once been visible, because `GradusMacApp` declared the scene without
/// a style. See that file for the regression note.
struct MenuContentView: View {
    static let columnWidth: CGFloat = 340
    static let fixedChromeHeight: CGFloat = 152
    static let providerRowSpacing: CGFloat = 5
    static let providerBarHeight: CGFloat = 8
    static let providerGroupSpacing: CGFloat = 10
    static let providerMetadataFont: MenuMetadataFont = .caption
    /// Every capacity bar shares the menu's left rail. Window labels carry
    /// hierarchy through their text, not by shifting their bar geometry.
    static let providerBarLeadingInset: CGFloat = 0

    /// A provider remains the heading for a single-window card. Window IDs
    /// describe quota mechanics (for example `premium` or `billing_cycle`),
    /// not subscription plans, so they belong in the reset-and-pace context
    /// rather than being promoted into the provider name.
    static func compactProviderLabel(providerName: String) -> String {
        providerName
    }

    @ObservedObject var viewModel: PublisherViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MenuHeader(
                providers: visibleProviders,
                localThreshold: viewModel.localWarningThresholdPercent
            )

            MenuProviderListView(
                providers: visibleProviders,
                sortOption: viewModel.providerSortOption,
                localThreshold: viewModel.localWarningThresholdPercent
            )
            .id(viewModel.presentationRevision)

            Divider()

            cloudSyncStatus
            backgroundAgentStatus
            Toggle(
                "Open Menu at Login",
                isOn: Binding(
                    get: { viewModel.launchAtLoginEnabled },
                    set: { viewModel.setLaunchAtLogin($0) }
                )
            )
            .accessibilityIdentifier("menu-open-menu-at-login")

            Divider()

            Button("Settings…") { SettingsWindow.show(viewModel: viewModel) }
                .accessibilityIdentifier("menu-settings-button")
            Button("Quit Gradus") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: MenuVerticalBudget.columnWidth)
        .accessibilityIdentifier("menu-content")
    }

    /// Applied here rather than in `PublisherViewModel.providers`, which is the
    /// mirror image of where iOS filters. On iOS that array feeds only the
    /// dashboard, so filtering at the model is the same thing. Here it also
    /// feeds `MenuHeader`'s attention count, and both must agree -- a header
    /// reading "3 need attention" above two rows is worse than either choice.
    /// Filtering once, at the point both are built, keeps them consistent
    /// without letting a display preference reach anything that alerts:
    /// the menu bar icon is computed from the publish payload in
    /// `GradusMacApp`, not from this array, so hiding a spent provider from
    /// the list never quiets the icon for it.
    ///
    /// Internal rather than private so the filter has a direct test. The
    /// alternative was a snapshot, which would prove a row is absent but not
    /// *why* -- and a filter that silently passed everything looks identical to
    /// a preference defaulting to on.
    var visibleProviders: [ProviderEntry] {
        viewModel.showExhausted
            ? viewModel.providers
            : viewModel.providers.filter { !$0.rankingIsDepleted }
    }

    /// "iCloud sync complete" answered the wrong question -- it reported the
    /// outcome of an event the user did not see and could not date. The
    /// timestamp answers "is what I'm looking at current", which is the only
    /// reason to read this line. `.idle` shows it too: the state enum resets
    /// on launch, so a long-running agent would otherwise show nothing at all
    /// despite having synced minutes earlier.
    @ViewBuilder
    private var cloudSyncStatus: some View {
        if viewModel.requiredICloudMode == .awaitingConfirmation {
            VStack(alignment: .leading, spacing: 4) {
                Text("Required iCloud setup is awaiting confirmation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Continue") {
                    viewModel.confirmRequiredICloud()
                    PublishPipeline.shared.start()
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            switch viewModel.syncState {
            case .publishing:
                Text("Syncing with iCloud…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed:
                VStack(alignment: .leading, spacing: 1) {
                    Text("iCloud sync failed. Will retry with the next update.")
                        .foregroundStyle(SignalColor.forLevel(.red))
                    // A failure is only actionable next to how stale it left you.
                    if let label = Self.lastSyncLabel(viewModel.lastSyncedAt) {
                        Text(label).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            case .idle, .synced:
                Text(Self.lastSyncLabel(viewModel.lastSyncedAt) ?? "Not synced yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The background-refresh half of "is what I'm looking at current".
    /// `cloudSyncStatus` above answers whether the *phone* has this data;
    /// this answers whether *this Mac* still collects it. A healthy agent says
    /// nothing -- the row exists to name a problem, not to congratulate itself.
    @ViewBuilder
    private var backgroundAgentStatus: some View {
        if !viewModel.backgroundAgentState.claimsCurrentData {
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.backgroundAgentState.headline)
                    .foregroundStyle(SignalColor.forLevel(.orange))
                Button("Fix in Settings…") { SettingsWindow.show(viewModel: viewModel) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("menu-agent-fix-button")
            }
            .font(.caption)
            .accessibilityIdentifier("menu-agent-status")
        }
    }

    /// Uses `friendlyDateLabel` -- the same helper behind the "resets …" copy
    /// on each row -- so the menu never shows two date vocabularies at once.
    static func lastSyncLabel(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        return "Last sync \(friendlyDateLabel(date, now: now))"
    }
}

/// The live `MenuBarExtra` root owns observation of the process-lifetime
/// model. `MenuContentView` remains an observed child because tests construct
/// it directly, outside a mounted SwiftUI hierarchy.
struct MenuBarContentRoot: View {
    @StateObject private var viewModel: PublisherViewModel

    init(viewModel: PublisherViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        MenuContentView(viewModel: viewModel)
    }
}

/// Deterministic DEBUG-only host for Mac XCUITests. It exercises the same
/// MenuContentView used by MenuBarExtra, without making the production
/// status-item path test-dependent or reading a user's snapshot/defaults.
struct MenuUITestFixtureView: View {
    @StateObject private var viewModel: PublisherViewModel

    init() {
        let suiteName = "com.zerodelta.gradus.mac.ui-tests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let viewModel = PublisherViewModel(
            defaults: defaults,
            // Present only when GradusMacUITests supplies a state file. Absent,
            // the fixture falls back to the ordinary manager, which reads the
            // live registration and never writes it.
            backgroundAgent: FileBackedBackgroundAgentService.fromEnvironment().map {
                BackgroundAgentManager(service: $0)
            }
        )
        viewModel.apply(
            SnapshotPayload(
                schemaVersion: supportedSchemaVersion,
                updatedAt: "2026-08-10T12:00:00-04:00",
                providers: [
                    ProviderEntry(
                        name: "Codex",
                        ok: true,
                        error: nil,
                        windows: [
                            ProviderWindow(
                                id: "five_hour", percentLeft: 72,
                                resetISO: "2026-08-10T17:00:00-04:00", windowHours: 5,
                                paceDelta: 0.12
                            ),
                            ProviderWindow(
                                id: "weekly", percentLeft: 44,
                                resetISO: "2026-08-12T09:00:00-04:00", windowHours: 168,
                                paceDelta: -0.02
                            )
                        ],
                        data: [:], observedAt: "2026-08-10T12:00:00-04:00"
                    ),
                    ProviderEntry(
                        name: "Cursor",
                        ok: true,
                        error: nil,
                        windows: [
                            ProviderWindow(
                                id: "monthly", percentLeft: 0,
                                resetISO: "2026-08-31T23:59:00-04:00", windowHours: 720,
                                paceDelta: -0.5
                            )
                        ],
                        data: [:], observedAt: "2026-08-10T12:00:00-04:00"
                    )
                ]
            )
        )
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        MenuContentView(viewModel: viewModel)
            // The fixture must leave room for the bottom controls' hit
            // targets. A 680-point minimum in a 720-point host intermittently
            // exposed the toggle but clipped its clickable bounds.
            .frame(minHeight: 760, alignment: .top)
            .padding(.top, 1)
    }
}

// DEBUG-only window host for the Mac UI-test fixture. A status-item app has
// no normal root window for XCUITest to launch, so the test seam owns one
// explicit window while the production MenuBarExtra path remains unchanged.
#if DEBUG
    enum MenuUITestFixtureWindow {
        private static var window: NSWindow?

        static func show() {
            NSApplication.shared.setActivationPolicy(.regular)
            let hostingController = NSHostingController(rootView: MenuUITestFixtureView())
            let window = NSWindow(contentViewController: hostingController)
            window.identifier = NSUserInterfaceItemIdentifier("gradus-ui-test-menu")
            window.title = "Gradus UI Test Menu"
            window.setContentSize(NSSize(width: MenuContentView.columnWidth + 24, height: 800))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setAccessibilityRole(.window)
            window.setAccessibilityElement(true)
            window.center()
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            self.window = window
            let policy = NSApplication.shared.activationPolicy().rawValue
            let windowCount = NSApplication.shared.windows.count
            fputs(
                "GRADUS_SHOW_END policy=\(policy) windows=\(windowCount) visible=\(window.isVisible)\n",
                stderr
            )
        }
    }
#endif
