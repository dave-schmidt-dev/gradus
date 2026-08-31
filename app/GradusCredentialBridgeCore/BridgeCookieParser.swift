// The Safari `Cookies.binarycookies` reader, split out of `Bridge.swift` so
// neither type body exceeds the 250-line limit. Everything here is parsing:
// it takes bytes and returns `Cookie` values, and it reaches nothing outside
// the buffer it is handed -- no Keychain, no network, no file system.

import Foundation

extension CredentialBridge {
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
