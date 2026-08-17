import Darwin
import Foundation

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

        if let claude = claudePayload(cookies, cachedAt: cachedAt) {
            try write(claude, named: "claude_cookies.json", to: cacheDirectory)
        }
        if let cursor = cursorPayload(cookies, cachedAt: cachedAt) {
            try write(cursor, named: "cursor_token.json", to: cacheDirectory)
        }
        if let opencode = openCodePayload(cookies, cachedAt: cachedAt) {
            try write(opencode, named: "opencode_go_cookies.json", to: cacheDirectory)
        }
        if let vibe = vibePayload(cookies, cachedAt: cachedAt) {
            try write(vibe, named: "vibe_cookies.json", to: cacheDirectory)
        }
    }

    static func parseCookies(_ data: Data) throws -> [Cookie] {
        guard data.count >= 8, data.prefix(4) == Data("cook".utf8) else {
            throw BridgeError.invalidCookieFile
        }
        let pageCount = try data.uint32BE(at: 4)
        guard pageCount <= 1024 else { throw BridgeError.invalidCookieFile }

        let pageSizes = try readPageSizes(count: pageCount, in: data)
        return try readCookies(fromPages: pageSizes, in: data)
    }

    /// Reads the page-size table that follows the file header, one big-endian
    /// `UInt32` per page, starting at offset 8.
    private static func readPageSizes(count: UInt32, in data: Data) throws -> [Int] {
        var offset = 8
        var pageSizes: [Int] = []
        for _ in 0 ..< count {
            let pageSize = try data.uint32BE(at: offset)
            guard pageSize >= 8, pageSize <= data.count else { throw BridgeError.invalidCookieFile }
            pageSizes.append(Int(pageSize))
            offset += 4
        }
        return pageSizes
    }

    /// Walks the pages described by `pageSizes`, starting immediately after the
    /// page-size table, and collects the cookies parsed from each page.
    private static func readCookies(fromPages pageSizes: [Int], in data: Data) throws -> [Cookie] {
        var offset = 8 + pageSizes.count * 4
        var cookies: [Cookie] = []
        for pageSize in pageSizes {
            guard offset + pageSize <= data.count else { throw BridgeError.invalidCookieFile }
            let page = data.subdata(in: offset ..< offset + pageSize)
            offset += pageSize
            try cookies.append(contentsOf: readCookies(inPage: page))
        }
        return cookies
    }

    /// Parses every cookie record referenced by a single page's offset table.
    private static func readCookies(inPage page: Data) throws -> [Cookie] {
        guard page.count >= 8 else { return [] }
        let cookieCount = try page.uint32LE(at: 4)
        guard cookieCount <= 4096, 8 + Int(cookieCount) * 4 <= page.count else {
            throw BridgeError.invalidCookieFile
        }
        var cookies: [Cookie] = []
        for index in 0 ..< cookieCount {
            let cookieOffset = try Int(page.uint32LE(at: 8 + Int(index) * 4))
            guard cookieOffset >= 0, cookieOffset < page.count else { continue }
            if let cookie = try readCookie(at: cookieOffset, in: page) {
                cookies.append(cookie)
            }
        }
        return cookies
    }

    /// Decodes a single cookie record starting at `cookieOffset` within `page`,
    /// or returns `nil` if any required field is missing, unparseable, or empty.
    private static func readCookie(at cookieOffset: Int, in page: Data) throws -> Cookie? {
        guard cookieOffset + 4 <= page.count else { return nil }
        let recordSize = try Int(page.uint32LE(at: cookieOffset))
        guard recordSize >= 56,
              recordSize <= page.count - cookieOffset
        else { return nil }
        let cookie = page.subdata(in: cookieOffset ..< cookieOffset + recordSize)
        let expiresAt: Date?
        let createdAt: Date?
        do {
            expiresAt = try macAbsoluteDate(in: cookie, at: 40)
            createdAt = try macAbsoluteDate(in: cookie, at: 48)
        } catch {
            return nil
        }
        let rawDomain: String?
        let name: String?
        let value: String?
        do {
            rawDomain = try cookie.cString(at: cookie.uint32LE(at: 16))
            name = try cookie.cString(at: cookie.uint32LE(at: 20))
            value = try cookie.cString(at: cookie.uint32LE(at: 28))
        } catch {
            return nil
        }
        guard let rawDomain,
              let name,
              let value,
              let host = normalizedHost(rawDomain),
              !name.isEmpty,
              !value.isEmpty
        else { return nil }
        return Cookie(host: host, name: name, value: value, expiresAt: expiresAt, createdAt: createdAt)
    }

    /// Safari stores cookie dates as seconds since the Mac absolute epoch.
    /// Zero denotes a session cookie; non-finite or negative values are malformed.
    private static func macAbsoluteDate(in cookie: Data, at offset: Int) throws -> Date? {
        let seconds = try cookie.doubleLE(at: offset)
        guard seconds.isFinite, seconds >= 0 else { throw BridgeError.invalidCookieFile }
        return seconds == 0 ? nil : Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// WebKit stores a cookie's domain in the URL field. Current Safari jars
    /// use a bare domain (often with a leading dot), while older fixtures and
    /// defensive callers may provide a full URL. Normalize both forms without
    /// accepting malformed or whitespace-bearing hosts.
    private static func normalizedHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = if let parsed = URLComponents(string: trimmed), let host = parsed.host {
            host
        } else {
            trimmed
        }
        let host = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !host.isEmpty,
              host.count <= 253,
              labels.allSatisfy({ label in
                  guard !label.isEmpty,
                        label.first != "-",
                        label.last != "-"
                  else { return false }
                  return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              })
        else { return nil }
        return host
    }

    private static func claudePayload(_ cookies: [Cookie], cachedAt: String) -> [String: String]? {
        let values = values(for: "claude.ai", in: cookies)
        guard let sessionKey = values["sessionKey"],
              sessionKey.hasPrefix("sk-ant-")
        else { return nil }
        var payload = [
            "sessionKey": sessionKey,
            "cf_clearance": values["cf_clearance"] ?? "",
            "cached_at": cachedAt
        ]
        if let org = values["lastActiveOrg"], !org.isEmpty {
            payload["lastActiveOrg"] = org
        }
        return payload
    }

    private static func cursorPayload(_ cookies: [Cookie], cachedAt: String) -> [String: String]? {
        let values = values(for: "cursor.com", in: cookies)
        guard let rawToken = values["WorkosCursorSessionToken"],
              let decoded = rawToken.removingPercentEncoding,
              let token = decoded.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).last,
              decoded.contains("::"),
              !token.isEmpty
        else { return nil }
        return ["access_token": String(token), "cached_at": cachedAt]
    }

    private static func openCodePayload(_ cookies: [Cookie], cachedAt: String) -> [String: String]? {
        guard let auth = values(for: "opencode.ai", in: cookies)["auth"] else { return nil }
        return ["auth": auth, "cached_at": cachedAt]
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

    private static func write(_ payload: [String: String], named filename: String, to directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let target = directory.appendingPathComponent(filename)
        let temporary = directory.appendingPathComponent("." + filename + "." + UUID().uuidString)
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

private extension Data {
    func uint32BE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw BridgeError.invalidCookieFile }
        return self[offset ..< offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func uint32LE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw BridgeError.invalidCookieFile }
        return self[offset ..< offset + 4].enumerated().reduce(0) { $0 | (UInt32($1.element) << UInt32($1.offset * 8)) }
    }

    func doubleLE(at offset: Int) throws -> Double {
        guard offset >= 0, offset + 8 <= count else { throw BridgeError.invalidCookieFile }
        let bits = self[offset ..< offset + 8].enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << UInt64($1.offset * 8))
        }
        return Double(bitPattern: bits)
    }

    func cString(at offset: UInt32) -> String? {
        let start = Int(offset)
        guard start >= 0, start < count else { return nil }
        let end = self[start...].firstIndex(of: 0) ?? endIndex
        return String(data: self[start ..< end], encoding: .utf8)
    }
}
