import Foundation
import UserNotifications

/// The two reset-alert choices are independent of the existing warning alerts.
public enum ResetAlertKind: String, Equatable, Sendable {
    case grant
    case refill
}

/// Only display data reaches the local notification scheduler. In particular,
/// neither account identity nor the private observation cache crosses this seam.
public struct ResetNotificationEvent: Equatable, Sendable {
    public let kind: ResetAlertKind
    public let providerName: String
    public let windowLabel: String?
    public let increase: Int
    public let currentCount: Int

    public init(
        kind: ResetAlertKind, providerName: String, windowLabel: String? = nil,
        increase: Int = 0, currentCount: Int = 0
    ) {
        self.kind = kind
        self.providerName = providerName
        self.windowLabel = windowLabel
        self.increase = increase
        self.currentCount = currentCount
    }

    var title: String {
        switch kind {
        case .grant: "New banked resets"
        case .refill: "Usage refilled"
        }
    }

    var body: String {
        switch kind {
        case .grant:
            "Codex added \(increase) banked reset\(increase == 1 ? "" : "s"). \(currentCount) available."
        case .refill:
            if let windowLabel, !windowLabel.isEmpty {
                "\(providerName) \(ProviderWindowLabel.label(for: windowLabel)) usage is available again."
            } else {
                "\(providerName) usage is available again."
            }
        }
    }
}

public enum ResetNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case requesting
    case denied
    case authorized

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized, .provisional, .ephemeral: self = .authorized
        @unknown default: self = .notDetermined
        }
    }
}

/// One injectable boundary for permission reads, prompts, and delivery. Tests
/// supply a fake, so hosted GradusMacTests never touch Notification Center.
@MainActor
public protocol ResetNotificationScheduling {
    func authorization() async -> ResetNotificationAuthorization
    func requestAuthorization() async -> ResetNotificationAuthorization
    func schedule(_ event: ResetNotificationEvent)
}

@MainActor
public final class LocalResetNotificationScheduler: ResetNotificationScheduling {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func authorization() async -> ResetNotificationAuthorization {
        let settings = await center.notificationSettings()
        return ResetNotificationAuthorization(settings.authorizationStatus)
    }

    public func requestAuthorization() async -> ResetNotificationAuthorization {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return .denied
        }
        return await authorization()
    }

    public func schedule(_ event: ResetNotificationEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "gradus-reset-\(UUID().uuidString)", content: content, trigger: nil
        )
        center.add(request) { error in
            if error != nil {
                GradusLog.app.warning("local reset notification could not be scheduled")
            }
        }
    }
}

/// The attended helper is launched only by the Settings action. Its output is
/// discarded because the UI needs only success/failure, never helper details.
@MainActor
public protocol BankedBackgroundAccessAuthorizing {
    func authorize() async -> Bool
}

@MainActor
public struct BundledBankedBackgroundAccessAuthorizer: BankedBackgroundAccessAuthorizing {
    private let runtimeURL: URL
    private let homeURL: URL

    public init(
        bundleURL: URL = Bundle.main.bundleURL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        runtimeURL = bundleURL.appendingPathComponent(
            "Contents/Helpers/GradusRuntime.app/Contents/MacOS/GradusRuntime"
        )
        self.homeURL = homeURL
    }

    public func authorize() async -> Bool {
        let runtimeURL = runtimeURL
        let homeURL = homeURL
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard FileManager.default.isExecutableFile(atPath: runtimeURL.path) else {
                    continuation.resume(returning: false)
                    return
                }
                let process = Process()
                process.executableURL = runtimeURL
                process.arguments = ["--authorize-banked-access"]
                let user = NSUserName()
                process.environment = [
                    "GRADUS_RUNTIME_MODE": "installed",
                    "HOME": homeURL.path,
                    "LANG": "en_US.UTF-8",
                    "LOGNAME": user,
                    "PATH": "\(homeURL.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                    "TMPDIR": NSTemporaryDirectory(),
                    "USER": user
                ]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
