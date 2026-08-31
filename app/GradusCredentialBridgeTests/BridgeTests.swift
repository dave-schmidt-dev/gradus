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

    func testParserNormalizesSafariDomainAndLegacyFullURLRepresentations() throws {
        let domain = try CredentialBridge.parseCookies(
            binaryCookies([.init(host: ".cursor.com", name: "fixture", value: "domain")])
        )
        XCTAssertEqual(domain, [.init(host: "cursor.com", name: "fixture", value: "domain")])

        let fullURL = try CredentialBridge.parseCookies(
            binaryCookies([.init(host: "cursor.com", name: "fixture", value: "url")], encodeFullURL: true)
        )
        XCTAssertEqual(fullURL, [.init(host: "cursor.com", name: "fixture", value: "url")])
    }

    func testCommandAcceptsOnlyFixedRefreshAndCheckOperations() {
        XCTAssertEqual(CredentialBridgeOperation(arguments: ["check"]), .check)
        let cache = URL(fileURLWithPath: "/tmp/Gradus/Private/.cache", isDirectory: true)
        XCTAssertEqual(
            CredentialBridgeOperation(arguments: ["refresh", "--cache-directory", cache.path]),
            .refresh(cacheDirectory: cache)
        )

        for arguments in [
            [String](),
            ["refresh"],
            ["refresh", "--cache-directory", "relative/.cache"],
            ["refresh", "--cache-directory", cache.path, "extra"],
            ["check", "extra"],
            ["arbitrary", "/bin/sh"]
        ] {
            XCTAssertNil(CredentialBridgeOperation(arguments: arguments), "accepted \(arguments)")
        }
    }

    func testRefreshRejectsNonCacheDirectoryBeforeReadingSafari() {
        XCTAssertThrowsError(try CredentialBridge.refresh(cacheDirectory: URL(fileURLWithPath: "/tmp/not-cache")))
    }

    func testRefreshWritesOnlyAllowedPayloadsWithPrivateModes() throws {
        let fixture = try makeFixture(cookies: [
            .init(host: "console.mistral.ai", name: "ory_session_fixture", value: "mistral-session"),
            .init(host: "console.mistral.ai", name: "csrftoken", value: "mistral-csrf"),
            .init(host: "evil.example", name: "example-token", value: "must-not-leak"),
            .init(host: "claude.ai", name: "sessionKey", value: "unused-keychain-provider-cookie")
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try CredentialBridge.refresh(cacheDirectory: fixture.cache, cookieFileURL: fixture.source)

        let vibe = try payload(named: "vibe_cookies.json", in: fixture.cache)
        XCTAssertEqual(vibe["ory_session_name"], "ory_session_fixture")
        XCTAssertEqual(vibe["ory_session_value"], "mistral-session")
        XCTAssertEqual(vibe["csrftoken"], "mistral-csrf")

        let filenames = try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).sorted()
        XCTAssertEqual(filenames, ["vibe_cookies.json"])
        for filename in filenames {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: fixture.cache.appendingPathComponent(filename).path
            )
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: fixture.cache.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testRefreshAcceptsInjectedInstalledPrivateCacheRoot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("Cookies.binarycookies")
        let cache = root
            .appendingPathComponent("Library/Application Support/Gradus/Private", isDirectory: true)
            .appendingPathComponent(".cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try binaryCookies([.init(host: "console.mistral.ai", name: "csrftoken", value: "fixture")]).write(to: source)

        try CredentialBridge.refresh(cacheDirectory: cache, cookieFileURL: source)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cache.appendingPathComponent("opencode_go_cookies.json").path)
        )
        try XCTAssertEqual(
            (FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
    }

    func testRefreshRemovesOnlyExactLegacyProviderCaches() throws {
        let fixture = try makeFixture(cookies: [
            .init(host: "console.mistral.ai", name: "ory_session_fixture", value: "mistral-session"),
            .init(host: "console.mistral.ai", name: "csrftoken", value: "mistral-csrf")
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let legacyCursor = fixture.cache.appendingPathComponent("cursor_token.json")
        let legacyOpenCode = fixture.cache.appendingPathComponent("opencode_go_cookies.json")
        let unrelated = fixture.cache.appendingPathComponent("keep-me.json")
        try FileManager.default.createDirectory(at: fixture.cache, withIntermediateDirectories: true)
        try Data("legacy-cursor".utf8).write(to: legacyCursor)
        try Data("legacy-opencode".utf8).write(to: legacyOpenCode)
        try Data("unrelated".utf8).write(to: unrelated)

        try CredentialBridge.refresh(cacheDirectory: fixture.cache, cookieFileURL: fixture.source)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyCursor.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyOpenCode.path))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "unrelated")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.cache.appendingPathComponent("vibe_cookies.json").path)
        )
    }

    func testCheckReturnsSuccessWithoutCredentialMaterial() throws {
        let fixture = try makeFixture(cookies: [
            .init(host: "example.invalid", name: "example-auth", value: "must-not-escape")
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = CredentialBridge.check(cookieFileURL: fixture.source)

        XCTAssertEqual(result, CredentialBridgeCheckResult(state: .success))
        let encoded = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema_version", "operation", "state"])
        XCTAssertEqual(object["operation"] as? String, "check")
        XCTAssertEqual(object["state"] as? String, "success")
        XCTAssertFalse(String(data: encoded, encoding: .utf8)?.contains("must-not-escape") ?? true)
    }

    func testCheckReturnsDeniedForUnreadableSafariStoreWithoutRawError() throws {
        let result = CredentialBridge.check(cookieFileURL: URL(fileURLWithPath: "/private/fixture")) { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }

        XCTAssertEqual(result.state, .denied)
        let text = try XCTUnwrap(String(data: JSONEncoder().encode(result), encoding: .utf8))
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains("permission"))
        XCTAssertFalse(text.contains("error"))
    }

    func testCheckReturnsMissingForAbsentSafariStore() {
        let result = CredentialBridge.check(cookieFileURL: URL(fileURLWithPath: "/missing/fixture")) { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        XCTAssertEqual(result.state, .missing)
    }

    func testCheckReturnsMalformedForInvalidOrOversizedSafariStore() {
        let invalid = CredentialBridge.check(cookieFileURL: URL(fileURLWithPath: "/malformed")) { _ in
            Data("not-a-cookie-store".utf8)
        }
        XCTAssertEqual(invalid.state, .malformed)

        let oversized = CredentialBridge.check(cookieFileURL: URL(fileURLWithPath: "/oversized")) { _ in
            Data(repeating: 0, count: 16 * 1024 * 1024 + 1)
        }
        XCTAssertEqual(oversized.state, .malformed)
    }

    func testParserSkipsShortRecordsAndMalformedDates() throws {
        var shortRecord = binaryCookies([.init(host: "example.invalid", name: "example-auth", value: "short")])
        shortRecord.replaceSubrange(24 ..< 28, with: littleEndian(UInt32(48)))
        XCTAssertTrue(try CredentialBridge.parseCookies(shortRecord).isEmpty)

        var malformedDate = binaryCookies([.init(host: "example.invalid", name: "example-auth", value: "nan")])
        malformedDate.replaceSubrange(64 ..< 72, with: littleEndian(Double.nan))
        XCTAssertTrue(try CredentialBridge.parseCookies(malformedDate).isEmpty)
    }

    private struct BridgeFixture {
        let root: URL
        let source: URL
        let cache: URL
    }

    private func makeFixture(cookies: [CredentialBridge.Cookie]) throws -> BridgeFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("Cookies.binarycookies")
        let cache = root.appendingPathComponent(".cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try binaryCookies(cookies).write(to: source)
        return BridgeFixture(root: root, source: source, cache: cache)
    }

    private func payload(named filename: String, in cache: URL) throws -> [String: String] {
        let data = try Data(contentsOf: cache.appendingPathComponent(filename))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    private func binaryCookies(_ entries: [CredentialBridge.Cookie], encodeFullURL: Bool = false) -> Data {
        var cookies: [Data] = []
        for entry in entries {
            let url = encodeFullURL ? "https://" + entry.host + "/" : entry.host
            let strings = [url, entry.name, entry.value].map { Data(($0 + "\0").utf8) }
            var cookie = Data(repeating: 0, count: 56)
            let recordSize = 56 + strings.reduce(0) { $0 + $1.count }
            cookie.replaceSubrange(0 ..< 4, with: littleEndian(UInt32(recordSize)))
            cookie.replaceSubrange(16 ..< 20, with: littleEndian(56))
            cookie.replaceSubrange(20 ..< 24, with: littleEndian(56 + strings[0].count))
            cookie.replaceSubrange(28 ..< 32, with: littleEndian(56 + strings[0].count + strings[1].count))
            cookie.replaceSubrange(40 ..< 48, with: littleEndian(entry.expiresAt?.timeIntervalSinceReferenceDate ?? 0))
            cookie.replaceSubrange(48 ..< 56, with: littleEndian(entry.createdAt?.timeIntervalSinceReferenceDate ?? 0))
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

    private func littleEndian(_ value: Double) -> Data {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { Data($0) }
    }

    private func bigEndian(_ value: Int) -> Data {
        bigEndian(UInt32(value))
    }

    private func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
