import Darwin
import Foundation

public enum CredentialBridgeOperation: Equatable {
    case refresh(cacheDirectory: URL)
    case check

    public init?(arguments: [String]) {
        if arguments == ["check"] {
            self = .check
            return
        }
        guard arguments.count == 3,
              arguments[0] == "refresh",
              arguments[1] == "--cache-directory",
              arguments[2].hasPrefix("/")
        else {
            return nil
        }
        self = .refresh(cacheDirectory: URL(fileURLWithPath: arguments[2], isDirectory: true))
    }
}

public struct CredentialBridgeCheckResult: Codable, Equatable {
    public enum State: String, Codable {
        case success
        case denied
        case missing
        case malformed
    }

    public let schemaVersion: Int
    public let operation: String
    public let state: State

    init(state: State) {
        schemaVersion = 1
        operation = "check"
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case operation
        case state
    }
}

public enum CredentialBridge {
    static let safariCookiesURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")

    private static let maximumCookieFileBytes = 16 * 1024 * 1024

    struct Cookie: Equatable {
        let host: String
        let name: String
        let value: String
        let expiresAt: Date?
        let createdAt: Date?

        init(host: String, name: String, value: String, expiresAt: Date? = nil, createdAt: Date? = nil) {
            self.host = host
            self.name = name
            self.value = value
            self.expiresAt = expiresAt
            self.createdAt = createdAt
        }
    }

    public static func refresh(cacheDirectory: URL) throws {
        try refresh(cacheDirectory: cacheDirectory, cookieFileURL: safariCookiesURL)
    }

    public static func check() -> CredentialBridgeCheckResult {
        check(cookieFileURL: safariCookiesURL) {
            try Data(contentsOf: $0, options: [.mappedIfSafe])
        }
    }

    static func check(
        cookieFileURL: URL,
        reader: (URL) throws -> Data = { try Data(contentsOf: $0, options: [.mappedIfSafe]) }
    ) -> CredentialBridgeCheckResult {
        let data: Data
        do {
            data = try reader(cookieFileURL)
        } catch {
            return CredentialBridgeCheckResult(state: readFailureState(error))
        }
        guard data.count <= maximumCookieFileBytes else {
            return CredentialBridgeCheckResult(state: .malformed)
        }
        do {
            _ = try parseCookies(data)
            return CredentialBridgeCheckResult(state: .success)
        } catch {
            return CredentialBridgeCheckResult(state: .malformed)
        }
    }

    static func refresh(cacheDirectory: URL, cookieFileURL: URL) throws {
        guard cacheDirectory.lastPathComponent == ".cache" else {
            throw BridgeError.invalidCacheDirectory
        }

        let data = try Data(contentsOf: cookieFileURL, options: [.mappedIfSafe])
        guard data.count <= maximumCookieFileBytes else {
            throw BridgeError.cookieFileTooLarge
        }
        let cookies = try parseCookies(data)
        let cachedAt = ISO8601DateFormatter().string(from: Date())

        try removeLegacyProviderCaches(from: cacheDirectory)

        if let vibe = vibePayload(cookies, cachedAt: cachedAt) {
            try write(vibe, named: .vibe, to: cacheDirectory)
        }
    }

    private static func vibePayload(_ cookies: [Cookie], cachedAt: String) -> [String: String]? {
        let values = values(for: "mistral.ai", in: cookies)
        guard let sessionName = values.keys.sorted().first(where: { $0.hasPrefix("ory_session_") }),
              let sessionValue = values[sessionName],
              let csrf = values["csrftoken"]
        else { return nil }
        return [
            "ory_session_name": sessionName,
            "ory_session_value": sessionValue,
            "csrftoken": csrf,
            "cached_at": cachedAt
        ]
    }

    private static func values(for domain: String, in cookies: [Cookie]) -> [String: String] {
        let now = Date()
        var selected: [String: Cookie] = [:]
        for cookie in cookies where cookie.host == domain || cookie.host.hasSuffix("." + domain) {
            if let expiresAt = cookie.expiresAt, expiresAt <= now {
                continue
            }
            guard let existing = selected[cookie.name] else {
                selected[cookie.name] = cookie
                continue
            }
            if isNewer(cookie, than: existing) {
                selected[cookie.name] = cookie
            }
        }
        return selected.mapValues(\.value)
    }

    private static func isNewer(_ candidate: Cookie, than existing: Cookie) -> Bool {
        switch (candidate.createdAt, existing.createdAt) {
        case let (candidate?, existing?) where candidate != existing:
            candidate > existing
        case (.some, nil):
            true
        case (nil, .some):
            false
        default:
            // Ties must not depend on Safari's record ordering.
            candidate.value < existing.value
        }
    }

    private enum CacheFileName: String {
        case vibe = "vibe_cookies.json"
    }

    /// Remove only credential caches owned by providers that no longer read
    /// Safari-derived material. Other files in the approved cache directory
    /// are intentionally left untouched.
    private static func removeLegacyProviderCaches(from directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for filename in ["cursor_token.json", "opencode_go_cookies.json"] {
            let path = directory.appendingPathComponent(filename)
            if manager.fileExists(atPath: path.path) {
                try manager.removeItem(at: path)
            }
        }
    }

    private static func readFailureState(_ error: Error) -> CredentialBridgeCheckResult.State {
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain, cocoa.code == NSFileReadNoSuchFileError {
            return .missing
        }
        if cocoa.domain == NSPOSIXErrorDomain, cocoa.code == Int(ENOENT) {
            return .missing
        }
        return .denied
    }

    private static func write(_ payload: [String: String], named filename: CacheFileName, to directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let target = directory.appendingPathComponent(filename.rawValue)
        let temporary = directory.appendingPathComponent("." + filename.rawValue + "." + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw BridgeError.cacheWriteFailed }
        defer {
            _ = close(descriptor)
            try? manager.removeItem(at: temporary)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw BridgeError.cacheWriteFailed }
        try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(descriptor) == 0, rename(temporary.path, target.path) == 0 else {
            throw BridgeError.cacheWriteFailed
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}

enum BridgeError: Error {
    case invalidCacheDirectory
    case cookieFileTooLarge
    case invalidCookieFile
    case cacheWriteFailed
}
