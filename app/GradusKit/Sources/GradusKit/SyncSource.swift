import Foundation

/// Non-secret identity of the Mac that most recently published a snapshot.
///
/// This is intentionally limited to the user-visible computer name and the
/// short local account name. It never carries an Apple ID, email address,
/// serial number, filesystem path, or credential material.
public struct SyncSource: Codable, Equatable, Sendable {
    public let computerName: String
    public let userName: String

    public init(computerName: String, userName: String) {
        self.computerName = Self.bound(computerName, fallback: "This Mac")
        self.userName = Self.bound(userName, fallback: "Unknown user")
    }

    private static func bound(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(256))
    }
}
