import Foundation
@testable import GradusCredentialBridgeCore
import XCTest

/// The refresh operation's exit status is the bridge's only channel to the
/// refresh agent. These pin that it carries the same credential-free
/// vocabulary `check` prints, so "denied" and "missing" stay distinguishable
/// upstream without any output.
final class BridgeExitStatusTests: XCTestCase {
    func testRefreshExitStatusCarriesTheCheckVocabularyWithoutCredentialMaterial() {
        // The refresh agent reads only this status. Pinned on both sides:
        // `RefreshAgentBridgeOutcomeTests.testBridgeExitStatusTableIsPinned` holds the
        // same numbers with no shared type.
        XCTAssertEqual(
            CredentialBridgeExitStatus.allCases.map(\.rawValue),
            [0, 1, 64, 65, 66, 67]
        )
        XCTAssertEqual(CredentialBridgeExitStatus.forRefreshError(BridgeError.cookieFileDenied), .denied)
        XCTAssertEqual(CredentialBridgeExitStatus.forRefreshError(BridgeError.cookieFileMissing), .missing)
        XCTAssertEqual(CredentialBridgeExitStatus.forRefreshError(BridgeError.cookieFileTooLarge), .malformed)
        XCTAssertEqual(CredentialBridgeExitStatus.forRefreshError(BridgeError.invalidCookieFile), .malformed)
        XCTAssertEqual(CredentialBridgeExitStatus.forRefreshError(BridgeError.invalidCacheDirectory), .failed)
        XCTAssertEqual(CredentialBridgeExitStatus.forRefreshError(BridgeError.cacheWriteFailed), .failed)
        XCTAssertEqual(
            CredentialBridgeExitStatus.forRefreshError(NSError(domain: "fixture", code: 7)),
            .failed
        )
    }

    func testRefreshTypesAMissingSafariStoreDistinctlyFromADeniedOne() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = root.appendingPathComponent(".cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let absent = root.appendingPathComponent("absent.binarycookies")
        XCTAssertThrowsError(try CredentialBridge.refresh(cacheDirectory: cache, cookieFileURL: absent)) { error in
            XCTAssertEqual(CredentialBridgeExitStatus.forRefreshError(error), .missing)
        }

        let malformed = root.appendingPathComponent("malformed.binarycookies")
        try Data("not-a-cookie-store".utf8).write(to: malformed)
        XCTAssertThrowsError(try CredentialBridge.refresh(cacheDirectory: cache, cookieFileURL: malformed)) { error in
            XCTAssertEqual(CredentialBridgeExitStatus.forRefreshError(error), .malformed)
        }

        let unreadable = root.appendingPathComponent("unreadable.binarycookies")
        try Data("sealed".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        XCTAssertThrowsError(try CredentialBridge.refresh(cacheDirectory: cache, cookieFileURL: unreadable)) { error in
            XCTAssertEqual(CredentialBridgeExitStatus.forRefreshError(error), .denied)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("vibe_cookies.json").path))
    }
}
