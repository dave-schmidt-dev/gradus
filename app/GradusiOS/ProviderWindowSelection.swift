import Foundation

/// A device-local window choice. This is intentionally not Codable and never
/// enters the cached `ProviderStatus` payload or CloudKit mapping.
public struct ProviderWindowSelection: Equatable, Hashable, Sendable {
    public let providerName: String
    public let windowID: String

    public init(providerName: String, windowID: String) {
        self.providerName = providerName
        self.windowID = windowID
    }
}
