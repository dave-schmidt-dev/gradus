import Foundation
@testable import GradusCredentialBridgeCore
import XCTest

final class BridgeTests: XCTestCase {
    func testParserReadsOnlyStructuredCookieFields() throws {
        let parsed = try CredentialBridge.parseCookies(
            binaryCookies([.init(host: "console.mistral.ai", name: "csrftoken", value: "fixture")])
        )
        XCTAssertEqual(parsed, [.init(host: "console.mistral.ai", name: "csrftoken", value: "fixture")])
    }

    func testRefreshRejectsNonCacheDirectoryBeforeReadingSafari() {
        XCTAssertThrowsError(try CredentialBridge.refresh(cacheDirectory: URL(fileURLWithPath: "/tmp/not-cache")))
    }

    func testRefreshWritesOnlyAllowedPayloadsWithPrivateModes() throws {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = temporary.appendingPathComponent("Cookies.binarycookies")
        let cache = temporary.appendingPathComponent(".cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try binaryCookies([
            .init(host: "claude.ai", name: "sessionKey", value: "claude-session"),
            .init(host: "claude.ai", name: "lastActiveOrg", value: "claude-org"),
            .init(host: "cursor.com", name: "WorkosCursorSessionToken", value: "user%3A%3Acursor-token"),
            .init(host: "opencode.ai", name: "auth", value: "opencode-auth"),
            .init(host: "console.mistral.ai", name: "ory_session_fixture", value: "mistral-session"),
            .init(host: "console.mistral.ai", name: "csrftoken", value: "mistral-csrf"),
            .init(host: "evilclaude.ai", name: "sessionKey", value: "must-not-leak")
        ]).write(to: source)

        try CredentialBridge.refresh(cacheDirectory: cache, cookieFileURL: source)

        let claude = try payload(named: "claude_cookies.json", in: cache)
        XCTAssertEqual(claude["sessionKey"], "claude-session")
        XCTAssertEqual(claude["cf_clearance"], "")
        let cursor = try payload(named: "cursor_token.json", in: cache)
        XCTAssertEqual(cursor["access_token"], "cursor-token")
        let opencode = try payload(named: "opencode_go_cookies.json", in: cache)
        XCTAssertEqual(opencode["auth"], "opencode-auth")
        let vibe = try payload(named: "vibe_cookies.json", in: cache)
        XCTAssertEqual(vibe["ory_session_name"], "ory_session_fixture")
        XCTAssertEqual(vibe["ory_session_value"], "mistral-session")
        XCTAssertEqual(vibe["csrftoken"], "mistral-csrf")
        for filename in ["claude_cookies.json", "cursor_token.json", "opencode_go_cookies.json", "vibe_cookies.json"] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: cache.appendingPathComponent(filename).path
            )
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: cache.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testMissingOpenCodeCookieLeavesCacheMissingUntilAUsableCookieReturns() throws {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = temporary.appendingPathComponent("Cookies.binarycookies")
        let cache = temporary.appendingPathComponent(".cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        try binaryCookies([.init(host: "console.mistral.ai", name: "csrftoken", value: "fixture")]).write(to: source)
        try CredentialBridge.refresh(cacheDirectory: cache, cookieFileURL: source)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cache.appendingPathComponent("opencode_go_cookies.json").path)
        )

        try binaryCookies([.init(host: "opencode.ai", name: "auth", value: "restored-cookie")]).write(to: source)
        try CredentialBridge.refresh(cacheDirectory: cache, cookieFileURL: source)
        let restored = try payload(named: "opencode_go_cookies.json", in: cache)
        XCTAssertEqual(restored["auth"], "restored-cookie")
    }

    private func payload(named filename: String, in cache: URL) throws -> [String: String] {
        let data = try Data(contentsOf: cache.appendingPathComponent(filename))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    private func binaryCookies(_ entries: [CredentialBridge.Cookie]) -> Data {
        var cookies: [Data] = []
        for entry in entries {
            let url = "https://" + entry.host + "/"
            let strings = [url, entry.name, entry.value].map { Data(($0 + "\0").utf8) }
            var cookie = Data(repeating: 0, count: 48)
            cookie.replaceSubrange(16 ..< 20, with: littleEndian(48))
            cookie.replaceSubrange(20 ..< 24, with: littleEndian(48 + strings[0].count))
            cookie.replaceSubrange(28 ..< 32, with: littleEndian(48 + strings[0].count + strings[1].count))
            strings.forEach { cookie.append($0) }
            cookies.append(cookie)
        }
        var page = Data("0000".utf8)
        page.append(littleEndian(UInt32(cookies.count)))
        var offset = 8 + 4 * cookies.count
        for cookie in cookies {
            page.append(littleEndian(UInt32(offset)))
            offset += cookie.count
        }
        cookies.forEach { page.append($0) }
        var file = Data("cook".utf8)
        file.append(bigEndian(1))
        file.append(bigEndian(UInt32(page.count)))
        file.append(page)
        return file
    }

    private func littleEndian(_ value: Int) -> Data {
        littleEndian(UInt32(value))
    }

    private func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private func bigEndian(_ value: Int) -> Data {
        bigEndian(UInt32(value))
    }

    private func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
