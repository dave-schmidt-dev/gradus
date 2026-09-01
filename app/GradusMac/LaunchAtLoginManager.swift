import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for the macOS publisher's
/// "Open Menu at Login" toggle (T2b.2) -- the app has no Background Modes
/// capability, so a launch-at-login affordance is how the publisher stays
/// realistically alive to receive snapshot file-change events.
///
/// Not the refresh agent. This registers the *main app* (`SMAppService.mainApp`)
/// so the menu-bar icon comes back after a restart; `BackgroundAgentManager`
/// registers the nested `SMAppService.agent(plistName:)` that keeps refreshing
/// with the menu quit. Both appear in Login Items, and the UI states which is
/// which, because "I turned that on" otherwise means two different things.
public enum LaunchAtLoginManager {
    public enum State: Equatable, Sendable {
        case enabled
        case disabled
        case requiresApproval
        case notFound
    }

    public static var currentState: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .disabled
        }
    }

    public static var isEnabled: Bool {
        currentState == .enabled
    }

    /// Registers (or unregisters) the app for launch-at-login. Throws on
    /// failure (e.g. sandboxing/permission issues) -- callers decide how to
    /// surface that to the user rather than this type silently swallowing it.
    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
