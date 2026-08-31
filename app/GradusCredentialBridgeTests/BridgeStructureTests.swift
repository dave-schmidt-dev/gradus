// Assertions about how the bridge is *built* rather than how it behaves:
// nested-app identity, Release signing, and the rule that Safari cookie-store
// reads stay confined to the bridge core. Split out of `BridgeTests.swift` so
// neither class exceeds the 250-line body limit; these read the staged app
// source tree, while the behaviour tests read only fixtures.

import Foundation
@testable import GradusCredentialBridgeCore
import XCTest

final class BridgeStructureTests: XCTestCase {
    private static let bridgeSourceRootEnvironmentKey = "GRADUS_BRIDGE_SOURCE_ROOT"

    func testNestedBridgeIdentityAndEmbeddingAreExplicit() throws {
        let appRoot = try stagedAppRoot()
        let project = try String(contentsOf: appRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let bridgeTarget = try XCTUnwrap(
            section(named: "GradusCredentialBridge", in: project, endingAt: "GradusRefreshAgentCore")
        )
        XCTAssertTrue(bridgeTarget.contains("PRODUCT_BUNDLE_IDENTIFIER: com.zerodelta.gradus.credential-bridge"))
        let macTarget = try XCTUnwrap(section(named: "GradusMac", in: project, endingAt: "GradusiOS"))
        let dependency = try XCTUnwrap(dependency(named: "GradusCredentialBridge", in: macTarget))
        XCTAssertTrue(dependency.contains("embed: true"))
        XCTAssertTrue(dependency.contains("codeSign: true"))
        XCTAssertTrue(dependency.contains("subpath: Contents/Helpers"))
    }

    func testNestedReleaseSigningMatchesDeveloperIDParentWithoutProfiles() throws {
        let appRoot = try stagedAppRoot()
        let project = try String(contentsOf: appRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let bridge = try XCTUnwrap(
            section(named: "GradusCredentialBridge", in: project, endingAt: "GradusRefreshAgentCore")
        )
        let agent = try XCTUnwrap(section(named: "GradusRefreshAgent", in: project, endingAt: "GradusMac"))
        let parent = try XCTUnwrap(section(named: "GradusMac", in: project, endingAt: "GradusiOS"))

        let bridgeRelease = try XCTUnwrap(releaseConfiguration(in: bridge))
        let agentRelease = try XCTUnwrap(releaseConfiguration(in: agent))
        let parentRelease = try XCTUnwrap(releaseConfiguration(in: parent))
        XCTAssertTrue(bridge.contains("SKIP_INSTALL: YES"))
        XCTAssertTrue(agent.contains("SKIP_INSTALL: YES"))
        for nestedRelease in [bridgeRelease, agentRelease] {
            XCTAssertTrue(nestedRelease.contains("CODE_SIGN_STYLE: Manual"))
            XCTAssertTrue(nestedRelease.contains("CODE_SIGN_IDENTITY: \"Developer ID Application\""))
            XCTAssertTrue(nestedRelease.contains("PROVISIONING_PROFILE_SPECIFIER: \"\""))
            XCTAssertEqual(signingIdentity(in: nestedRelease), signingIdentity(in: parentRelease))
        }
    }

    func testSafariCookieStoreReadIsConfinedToBridgeCore() throws {
        let appRoot = try stagedAppRoot()
        let repositoryRoot = appRoot.deletingLastPathComponent()
        let bridgeSource = try String(
            contentsOf: appRoot.appendingPathComponent("GradusCredentialBridgeCore/Bridge.swift"),
            encoding: .utf8
        )
        XCTAssertEqual(bridgeSource.components(separatedBy: "Cookies.binarycookies").count - 1, 1)
        XCTAssertEqual(bridgeSource.components(separatedBy: "com.apple.Safari").count - 1, 1)

        for root in [
            appRoot.appendingPathComponent("GradusMac"),
            appRoot.appendingPathComponent("GradusRefreshAgent"),
            appRoot.appendingPathComponent("packaging"),
            repositoryRoot.appendingPathComponent("gradus")
        ] {
            for source in sourceFiles(under: root) {
                let text = try String(contentsOf: source, encoding: .utf8)
                XCTAssertFalse(text.contains("Cookies.binarycookies"), "Safari store leaked into \(source.path)")
                XCTAssertFalse(
                    text.contains("com.apple.Safari/Data/Library/Cookies"),
                    "Safari path leaked into \(source.path)"
                )
            }
        }
    }

    private func stagedAppRoot() throws -> URL {
        guard let rawRoot = ProcessInfo.processInfo.environment[Self.bridgeSourceRootEnvironmentKey],
              !rawRoot.isEmpty
        else {
            throw BridgeStructuralFixtureError(
                "\(Self.bridgeSourceRootEnvironmentKey) must point to the gate-staged app "
                    + "source root; checkout fallback is disabled"
            )
        }
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw BridgeStructuralFixtureError(
                "\(Self.bridgeSourceRootEnvironmentKey) does not name a staged app directory: \(root.path)"
            )
        }
        return root
    }

    private func section(named name: String, in text: String, endingAt nextName: String) -> String? {
        guard let start = text.range(of: "  \(name):\n"),
              let end = text.range(of: "  \(nextName):\n", range: start.upperBound ..< text.endIndex)
        else { return nil }
        return String(text[start.lowerBound ..< end.lowerBound])
    }

    private func dependency(named name: String, in target: String) -> String? {
        guard let start = target.range(of: "      - target: \(name)\n") else { return nil }
        let remainder = start.upperBound ..< target.endIndex
        let end = target.range(of: "\n      - target:", range: remainder)?.lowerBound ?? target.endIndex
        return String(target[start.lowerBound ..< end])
    }

    private func releaseConfiguration(in target: String) -> String? {
        guard let start = target.range(of: "\n        Release:\n") else { return nil }
        let remainder = start.upperBound ..< target.endIndex
        let end = target.range(of: "\n        Debug:\n", range: remainder)?.lowerBound ?? target.endIndex
        return String(target[start.lowerBound ..< end])
    }

    private func signingIdentity(in configuration: String) -> String? {
        configuration.split(separator: "\n").first { $0.contains("CODE_SIGN_IDENTITY:") }
            .map(String.init)
    }

    private func sourceFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  ["swift", "py", "sh", "spec"].contains(url.pathExtension)
            else { return nil }
            return url
        }
    }
}

private struct BridgeStructuralFixtureError: LocalizedError {
    let errorDescription: String?

    init(_ description: String) {
        errorDescription = description
    }
}
