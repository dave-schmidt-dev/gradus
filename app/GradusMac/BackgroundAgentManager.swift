import AppKit
import Foundation
import GradusKit
import ServiceManagement

/// What `SMAppService` reports for the nested refresh agent.
public enum BackgroundAgentRegistration: String, Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
}

/// The seam over `SMAppService.agent(plistName:)`.
///
/// Registration mutates real system state and, once approved, survives this
/// process. Nothing in the test suite may touch the live service, so every
/// caller takes this protocol and the tests inject a recording fake.
public protocol BackgroundAgentServicing: AnyObject {
    var registration: BackgroundAgentRegistration { get }
    func register() throws
    func unregister() throws
}

/// Production implementation. The plist is the one embedded at
/// `Contents/Library/LaunchAgents/`; `SMAppService.agent` addresses it by file
/// name, which is why the copy-files build phase and this constant have to
/// agree.
public final class SMAppServiceBackgroundAgent: BackgroundAgentServicing {
    public static let plistName = "com.zerodelta.gradus.refresh-agent.plist"

    private var service: SMAppService {
        .agent(plistName: Self.plistName)
    }

    public init() {}

    public var registration: BackgroundAgentRegistration {
        switch service.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    public func register() throws {
        try service.register()
    }

    public func unregister() throws {
        try service.unregister()
    }
}

#if DEBUG
    /// A registration whose state lives in a file the UI harness owns.
    ///
    /// The quit-lifecycle fixture has to prove a registered agent is still
    /// registered after GradusMac exits, and it cannot do that by registering a
    /// real one: `SMAppService.register()` mutates the developer's machine and
    /// an approved agent outlives the test process. Backing the state with a
    /// file makes the claim observable across two launches while every write
    /// stays inside the harness's own temporary directory.
    final class FileBackedBackgroundAgentService: BackgroundAgentServicing {
        static let environmentKey = "GRADUS_UI_TEST_AGENT_STATE"

        private let fileURL: URL

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        /// `nil` outside the harness, so the production path can never pick
        /// this up by accident.
        static func fromEnvironment(
            _ environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> FileBackedBackgroundAgentService? {
            guard let path = environment[environmentKey], !path.isEmpty else { return nil }
            return FileBackedBackgroundAgentService(fileURL: URL(fileURLWithPath: path))
        }

        var registration: BackgroundAgentRegistration {
            guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return .notRegistered
            }
            return BackgroundAgentRegistration(
                rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)
            ) ?? .notRegistered
        }

        func register() throws {
            try write(.enabled)
        }

        func unregister() throws {
            try write(.notRegistered)
        }

        private func write(_ value: BackgroundAgentRegistration) throws {
            try value.rawValue.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
#endif

/// Coordinates the three things the setup/health UI needs: what
/// `SMAppService` says, what the agent's status file says, and the fixed
/// recovery actions. Not an `ObservableObject` on purpose -- `PublisherViewModel`
/// publishes the resolved state so the menu and Settings observe one object.
@MainActor
public final class BackgroundAgentManager {
    private let service: BackgroundAgentServicing
    private let statusFileURL: URL
    private let bridgeURL: URL
    private let now: () -> Date
    private let openURL: (URL) -> Void
    private let revealInFinder: (URL) -> Void

    /// The pane deep link. `x-apple.systempreferences:` is the only supported
    /// way in; there is no API that adds an app to Full Disk Access, which is
    /// exactly why `Reveal Credential Bridge` has to come first.
    public static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    )!
    public static let loginItemsSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    )!

    public init(
        service: BackgroundAgentServicing = SMAppServiceBackgroundAgent(),
        statusFileURL: URL = BackgroundAgentManager.defaultStatusFileURL,
        bridgeURL: URL = BackgroundAgentManager.defaultCredentialBridgeURL,
        now: @escaping () -> Date = Date.init,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        revealInFinder: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    ) {
        self.service = service
        self.statusFileURL = statusFileURL
        self.bridgeURL = bridgeURL
        self.now = now
        self.openURL = openURL
        self.revealInFinder = revealInFinder
    }

    /// Beside the canonical installed snapshot, written by the agent itself.
    /// Derived from `PublishPipeline.defaultSnapshotPath` rather than rebuilt,
    /// so INV-7 keeps exactly one place where that directory is constructed.
    public nonisolated static var defaultStatusFileURL: URL {
        PublishPipeline.agentStatusPath(for: PublishPipeline.defaultSnapshotPath)
    }

    /// The nested bridge inside this bundle. Resolved from `Bundle.main` rather
    /// than a literal so a relocated or renamed wrapper still reveals the right
    /// helper -- the whole point of the affordance is that the user cannot find
    /// it themselves.
    public nonisolated static var defaultCredentialBridgeURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/GradusCredentialBridge.app", isDirectory: true)
    }

    public var registration: BackgroundAgentRegistration {
        service.registration
    }

    public var isMonitoringEnabled: Bool {
        service.registration == .enabled
    }

    /// Reads the agent's credential-free status file. A missing or unparsable
    /// file is `nil`, never a fabricated healthy state.
    public func currentStatus() -> BackgroundAgentStatusFile? {
        guard let data = try? Data(contentsOf: statusFileURL) else { return nil }
        return try? JSONDecoder().decode(BackgroundAgentStatusFile.self, from: data)
    }

    public func state(providers: [ProviderEntry], snapshotUpdatedAt: Date?) -> BackgroundAgentState {
        BackgroundAgentStatusResolver.state(
            registration: service.registration,
            agentStatus: currentStatus(),
            snapshotUpdatedAt: snapshotUpdatedAt,
            providers: providers,
            now: now()
        )
    }

    /// Returns the registration the service actually reports afterwards, not
    /// the state that was asked for: `register()` on an unapproved agent
    /// succeeds and leaves it `requiresApproval`, and reporting that honestly
    /// is the difference between a working toggle and one that snaps back with
    /// no explanation.
    @discardableResult
    public func setMonitoringEnabled(_ enabled: Bool) -> BackgroundAgentRegistration {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            GradusLog.app.warning(
                "could not set background monitoring to \(enabled): \(error.localizedDescription)"
            )
        }
        return service.registration
    }

    public func perform(_ action: BackgroundAgentRecovery) {
        switch action {
        case .enableMonitoring:
            setMonitoringEnabled(true)
        case .openLoginItemsSettings:
            openURL(Self.loginItemsSettingsURL)
        case .revealCredentialBridge:
            revealInFinder(bridgeURL)
        case .openFullDiskAccessSettings:
            openURL(Self.fullDiskAccessSettingsURL)
        case .signIn, .installPrerequisite, .reinstallApp:
            // Explanatory-only: Gradus never runs a provider's login command on
            // the user's behalf, and never reinstalls itself.
            break
        }
    }
}
