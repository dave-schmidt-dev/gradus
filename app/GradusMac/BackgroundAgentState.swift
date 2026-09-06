import Foundation
import GradusKit

/// The credential-free status file the refresh agent writes after every phase
/// transition. Mirrors `GradusRefreshAgent`'s `AgentStatus` exactly; the two
/// are pinned to one shape by `BackgroundAgentManagerTests`.
public struct BackgroundAgentStatusFile: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case acquiringLock
        case alreadyRunning
        case bridgeWaiting
        case degraded
        case producerWaiting
        case restoringSnapshot
        case succeeded
        case failed
        case cancelled
    }

    public enum Health: String, Codable, Sendable {
        case normal
        case degraded
    }

    /// What the credential bridge's exit status said, in the bridge's own
    /// fixed vocabulary. Absent from a status written before the bridge ran,
    /// and from any file an older agent wrote.
    public enum Bridge: String, Codable, Sendable {
        case success
        case denied
        case missing
        case malformed
        case failed
        case timedOut
    }

    public let schemaVersion: Int
    public let phase: Phase
    public let health: Health
    public let bridge: Bridge?
    public let sequence: Int
    public let updatedAt: String

    public init(
        schemaVersion: Int = 1,
        phase: Phase,
        health: Health,
        bridge: Bridge? = nil,
        sequence: Int,
        updatedAt: String
    ) {
        self.schemaVersion = schemaVersion
        self.phase = phase
        self.health = health
        self.bridge = bridge
        self.sequence = sequence
        self.updatedAt = updatedAt
    }

    /// True while a refresh is in flight, which is what entitles the UI to show
    /// progress instead of a terminal state.
    public var isInFlight: Bool {
        switch phase {
        case .acquiringLock, .bridgeWaiting, .producerWaiting, .restoringSnapshot: true
        case .alreadyRunning, .degraded, .succeeded, .failed, .cancelled: false
        }
    }

    /// Short, credential-free progress copy. INV-1: a wait the user can see is
    /// the difference between "working" and "hung".
    public var progressDescription: String {
        switch phase {
        case .acquiringLock: "Starting a refresh…"
        case .alreadyRunning: "A refresh is already running."
        case .bridgeWaiting: "Checking your provider sign-ins…"
        case .degraded: "Continuing without the credential bridge…"
        case .producerWaiting: "Collecting provider usage…"
        case .restoringSnapshot: "Restoring the last good snapshot…"
        case .succeeded: "Refresh complete."
        case .failed: "The last refresh failed."
        case .cancelled: "The last refresh was cancelled."
        }
    }
}

/// Everything the setup and health UI is allowed to say about background
/// refresh. Deliberately an enum rather than a bag of booleans: "registered but
/// stale" and "running" have to be impossible to render at the same time.
public enum BackgroundAgentState: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case notFound
    case refreshing(BackgroundAgentStatusFile)
    case fullDiskAccessDenied
    case providerAuthRequired([String])
    case prerequisiteMissing([String])
    /// The agent finished without the bridge. The payload is the bridge's own
    /// typed outcome; nil means an agent that predates the field.
    case degraded(BackgroundAgentStatusFile.Bridge?)
    case stale(lastRefresh: Date?)
    case running(lastRefresh: Date?)
}

/// The fixed set of things a user can do about a state. Each case maps to one
/// button; a state with no actions is a state that needs nothing from them.
public enum BackgroundAgentRecovery: Equatable, Sendable, Identifiable {
    case enableMonitoring
    case openLoginItemsSettings
    case revealCredentialBridge
    case openFullDiskAccessSettings
    case reinstallApp

    public var id: String {
        title
    }

    public var title: String {
        switch self {
        case .enableMonitoring: "Turn On Monitor in Background"
        case .openLoginItemsSettings: "Open Login Items Settings"
        case .revealCredentialBridge: "Reveal Credential Bridge"
        case .openFullDiskAccessSettings: "Open Full Disk Access Settings"
        case .reinstallApp: "Reinstall Gradus"
        }
    }
}

public extension BackgroundAgentState {
    /// One line, always answering "is my usage data current?" first.
    var headline: String {
        switch self {
        case .notRegistered: "Background refresh is off"
        case .requiresApproval: "Waiting for your approval in Login Items"
        case .notFound: "Background refresh is unavailable"
        case let .refreshing(status): status.progressDescription
        case .fullDiskAccessDenied: "Full Disk Access is denied"
        case .providerAuthRequired: "A provider needs you to sign in"
        case .prerequisiteMissing: "A provider is missing something it needs"
        case .degraded: "Refreshing with reduced coverage"
        case .stale: "Usage data is out of date"
        case .running: "Refreshing in the background"
        }
    }

    /// The sentence that makes the headline actionable. Never contains a
    /// credential, a path into the cache, or raw helper output.
    var explanation: String {
        switch self {
        case .notRegistered:
            "Gradus only updates while its menu is open. Turn on Monitor in Background to keep usage current."
        case .requiresApproval:
            "macOS is holding the background agent until you allow it under Login Items & Extensions."
        case .notFound:
            "The background agent is missing from this copy of Gradus. Reinstalling restores it."
        case let .refreshing(status):
            status.isInFlight
                ? "This usually takes under two minutes."
                : "The agent reported this on its last run."
        case .fullDiskAccessDenied:
            "The credential bridge cannot read Safari's cookie store. Reveal the bridge first, then add that "
                + "exact app to Full Disk Access — adding Gradus itself will not grant it."
        case let .providerAuthRequired(providers):
            "\(Self.list(providers)) has no usable session. Sign in again where that provider authenticates: "
                + "its own CLI, or Safari for Vibe. Gradus never asks for the credential itself."
        case let .prerequisiteMissing(providers):
            "\(Self.list(providers)) needs a tool or account setup that is not present on this Mac."
        case let .degraded(bridge):
            Self.degradedExplanation(bridge)
        case .stale:
            "The last refresh did not produce new data. What is shown is the last good reading, not a live one."
        case .running:
            "The background agent is registered and its last refresh succeeded."
        }
    }

    var recoveryActions: [BackgroundAgentRecovery] {
        switch self {
        case .notRegistered: [.enableMonitoring]
        case .requiresApproval: [.openLoginItemsSettings]
        case .notFound: [.reinstallApp]
        case .refreshing: []
        // Reveal first, deliberately: the Full Disk Access pane needs the user
        // to drag in the nested bridge, and there is no way to find a helper
        // inside a bundle from that pane alone.
        case .fullDiskAccessDenied: [.revealCredentialBridge, .openFullDiskAccessSettings]
        // Signing in happens in the provider's own tool or in Safari; a button
        // here could only explain, and a button that only explains reads as a
        // fix that does nothing. The explanation carries the instruction.
        case .providerAuthRequired, .prerequisiteMissing: []
        case let .degraded(bridge):
            switch bridge {
            // An agent that predates the typed outcome: the pre-existing best
            // guess, since denial was the only bridge failure ever seen.
            case nil, .denied: [.revealCredentialBridge, .openFullDiskAccessSettings]
            case .success, .missing, .malformed, .failed, .timedOut: []
            }
        case .stale: [.openLoginItemsSettings]
        case .running: []
        }
    }

    /// True only when data the user is looking at is both fresh and produced by
    /// a healthy agent. Nothing may report "connected" from a stale snapshot.
    var claimsCurrentData: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    private static func degradedExplanation(_ bridge: BackgroundAgentStatusFile.Bridge?) -> String {
        let consequence = "Vibe is showing its last good reading; no other provider depends on the bridge."
        switch bridge {
        case nil:
            return "The credential bridge did not run, so any provider that depends on it is showing its last "
                + "good reading."
        case .denied:
            return "The credential bridge cannot read Safari's cookie store. " + consequence
        case .success:
            return "The credential bridge ran, but the refresh still reported reduced coverage. " + consequence
        case .missing:
            return "Safari has no cookie store on this Mac yet, so there is no console.mistral.ai session to "
                + "read. Open Safari and sign in at console.mistral.ai. " + consequence
        case .malformed:
            return "Safari's cookie store could not be read in the format the credential bridge expects. "
                + consequence
        case .failed:
            return "The credential bridge exited with an error. It runs again on the next refresh. " + consequence
        case .timedOut:
            return "The credential bridge did not finish within its deadline. It runs again on the next refresh. "
                + consequence
        }
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: "A provider"
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + ", and " + (names.last ?? "")
        }
    }
}

/// Turns registration, the agent's status file, and the published snapshot into
/// exactly one state.
///
/// A pure function on purpose. Every branch here is a claim the UI makes about
/// the user's machine, and the only way to test all of them without registering
/// a live agent or denying a real TCC grant is to make the inputs data.
public enum BackgroundAgentStatusResolver {
    /// Beyond this, a snapshot is reported as stale rather than current. The
    /// agent's own `StartInterval` is 120s; three missed runs plus slack is the
    /// smallest gap that cannot be a single slow probe.
    public static let staleAfter: TimeInterval = 15 * 60

    public static func state(
        registration: BackgroundAgentRegistration,
        agentStatus: BackgroundAgentStatusFile?,
        snapshotUpdatedAt: Date?,
        providers: [ProviderEntry],
        now: Date,
        staleAfter: TimeInterval = BackgroundAgentStatusResolver.staleAfter
    ) -> BackgroundAgentState {
        switch registration {
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .enabled: break
        }

        if let agentStatus, agentStatus.isInFlight {
            return .refreshing(agentStatus)
        }

        // The bridge's own typed denial outranks provider text. Without it, a
        // provider whose cache the bridge never wrote reports "no session",
        // which reads as "sign in" when the fix is a Full Disk Access grant.
        if agentStatus?.bridge == .denied {
            return .fullDiskAccessDenied
        }

        // Provider-attributed causes outrank a bare "degraded" or "stale":
        // both of those describe the symptom, and only one of these names what
        // the user has to do about it.
        if let attributed = providerAttributedState(providers) {
            return attributed
        }

        if let agentStatus, agentStatus.health == .degraded || agentStatus.phase == .degraded {
            return .degraded(agentStatus.bridge)
        }
        if let agentStatus, agentStatus.phase == .failed || agentStatus.phase == .cancelled {
            return .stale(lastRefresh: snapshotUpdatedAt)
        }

        guard let snapshotUpdatedAt, now.timeIntervalSince(snapshotUpdatedAt) <= staleAfter else {
            return .stale(lastRefresh: snapshotUpdatedAt)
        }
        return .running(lastRefresh: snapshotUpdatedAt)
    }

    /// The first cause a provider's own typed failure text can name. Split out
    /// of `state` so each classification stays one readable pass rather than
    /// another branch in an already long precedence chain.
    static func providerAttributedState(_ providers: [ProviderEntry]) -> BackgroundAgentState? {
        if providers.contains(where: fullDiskAccessDenied) {
            return .fullDiskAccessDenied
        }
        let authRequired = providers.filter(authenticationRequired).map(\.name).sorted()
        if !authRequired.isEmpty {
            return .providerAuthRequired(authRequired)
        }
        let missing = providers.filter(prerequisiteMissing).map(\.name).sorted()
        if !missing.isEmpty {
            return .prerequisiteMissing(missing)
        }
        return nil
    }

    /// Matched on the provider's own published failure text, which is typed and
    /// credential-free by INV-6. Nothing here reads a cache or a cookie.
    static func fullDiskAccessDenied(_ provider: ProviderEntry) -> Bool {
        guard let error = failureText(provider) else { return false }
        return error.contains("full disk access")
            || error.contains("operation not permitted")
            || error.contains("bridge denied")
    }

    static func authenticationRequired(_ provider: ProviderEntry) -> Bool {
        guard let error = failureText(provider) else { return false }
        return error.contains("auth required")
            || error.contains("session expired")
            || error.contains("session unavailable")
            || error.contains("re-authenticate")
            || error.contains("login`")
            || error.contains("authorization denied")
    }

    static func prerequisiteMissing(_ provider: ProviderEntry) -> Bool {
        guard let error = failureText(provider) else { return false }
        if authenticationRequired(provider) || fullDiskAccessDenied(provider) {
            return false
        }
        return error.contains("not installed")
            || error.contains("command not found")
            || error.contains("item unavailable")
            || error.contains("no such file")
    }

    /// A provider that published a carry marker is deliberately quiet: its own
    /// probe already said the reading is expected-stale and still good.
    private static func failureText(_ provider: ProviderEntry) -> String? {
        guard !provider.rankingIsOK, let error = provider.error else { return nil }
        return error.lowercased()
    }
}
