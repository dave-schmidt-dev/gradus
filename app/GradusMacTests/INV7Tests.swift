import Foundation
import Testing

// INV-7: "The CloudKit publisher takes its snapshot data through a single
// injected snapshot-path dependency, and its source references no
// credential path." This is a grep tripwire (PW, plan §8/§7) -- it catches
// obvious drift (a new hardcoded path, a stray credential string) but is
// not a proof; PM-15's fs_usage runtime canary check is deferred
// beta-hardening, not this gate.

private let inv7SourceRootEnvironmentKey = "GRADUS_INV7_SOURCE_ROOT"
private let xcodeCloudEnvironmentKey = "CI_XCODE_CLOUD"
private let xcodeCloudWorkspaceEnvironmentKey = "CI_WORKSPACE_PATH"

private func xcodeCloudPublisherSourceRoot(in environment: [String: String]) -> URL? {
    guard
        environment[xcodeCloudEnvironmentKey]?.uppercased() == "TRUE",
        let workspacePath = environment[xcodeCloudWorkspaceEnvironmentKey],
        !workspacePath.isEmpty
    else { return nil }

    return URL(fileURLWithPath: workspacePath, isDirectory: true)
        .appendingPathComponent("app/GradusMac", isDirectory: true)
}

private func publisherSourceFiles(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
    // This test is hosted by GradusMac.app. Never derive the source path from
    // #filePath: that points back into the checkout, which is commonly under
    // ~/Documents and makes the app test host cross the macOS TCC boundary.
    // test-gate.sh stages the source into its run-scoped DerivedData directory
    // and supplies this path explicitly.
    guard
        let rawSourceRoot = environment[inv7SourceRootEnvironmentKey]
        ?? xcodeCloudPublisherSourceRoot(in: environment)?.path,
        !rawSourceRoot.isEmpty
    else { return [] }

    let gradusMacDir = URL(fileURLWithPath: rawSourceRoot, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard
        FileManager.default.fileExists(atPath: gradusMacDir.path, isDirectory: &isDirectory),
        isDirectory.boolValue
    else { return [] }

    guard
        let enumerator = FileManager.default.enumerator(
            at: gradusMacDir, includingPropertiesForKeys: nil
        )
    else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

@Test func xcodeCloudPublisherSourceRootUsesTheTemporaryWorkspace() {
    let root = xcodeCloudPublisherSourceRoot(in: [
        xcodeCloudEnvironmentKey: "TRUE",
        xcodeCloudWorkspaceEnvironmentKey: "/tmp/xcode-cloud-workspace"
    ])
    #expect(root?.path == "/tmp/xcode-cloud-workspace/app/GradusMac")
}

@Test func publisherSourceRootDoesNotFallbackToTheCheckoutOutsideXcodeCloud() {
    #expect(xcodeCloudPublisherSourceRoot(in: [:]) == nil)
}

@Test func xcodeCloudSnapshotRootUsesTheTemporaryWorkspace() {
    let root = xcodeCloudSnapshotRoot(in: [
        "CI_XCODE_CLOUD": "TRUE",
        "CI_WORKSPACE_PATH": "/tmp/xcode-cloud-workspace"
    ])
    #expect(root?.path == "/tmp/xcode-cloud-workspace/app/GradusMacTests/__Snapshots__")
}

/// Dot-prefixed terms name *files*, so a following letter means the match is
/// part of a longer identifier rather than a filename: `.environment` is not
/// `.env`, and `.sshString` would not be `.ssh`. Matching these as bare
/// substrings produced a false positive the first time any source touched
/// `ProcessInfo.processInfo.environment`, and would fire on SwiftUI's very
/// common `.environment(_:)` modifier too.
///
/// The bare-substring rule is kept for every other term on purpose --
/// `mySecret` and `apiKeyPath` must still trip the wire. Narrowing applies
/// only where the term is a filename by construction.
private let filenameTerms: Set<String> = [".env", ".ssh", ".netrc"]

private func referencesForbiddenTerm(_ term: String, in lowered: String) -> Bool {
    guard filenameTerms.contains(term) else { return lowered.contains(term) }
    var searchStart = lowered.startIndex
    while let range = lowered.range(of: term, range: searchStart ..< lowered.endIndex) {
        let next = range.upperBound
        if next == lowered.endIndex || !lowered[next].isLetter {
            return true
        }
        searchStart = range.upperBound
    }
    return false
}

/// Counting raw occurrences counts the ones in prose too, and a comment
/// explaining why a file *avoids* an API is not a call site.
///
/// On 2026-08-06 a comment in `GradusLog.swift` reading "not
/// `NSHomeDirectory()`, because INV7Tests counts its call sites" failed the
/// call-site test — twice over, by saying so. Rewording it would have passed
/// while leaving the next person to hit the same wall with a failure message
/// that explains nothing.
///
/// Same shape as the `.env` narrowing above: drop a false-positive class
/// without touching the true-positive one. Code after `//` does not run, so a
/// call site cannot hide there. Line comments only — this codebase uses `///`
/// and `//`, and a block-comment parser would be more machinery than the
/// tripwire itself.
private func strippingLineComments(_ contents: String) -> String {
    contents
        .components(separatedBy: .newlines)
        .map { line -> Substring in
            guard let marker = line.range(of: "//") else { return line[...] }
            return line[line.startIndex ..< marker.lowerBound]
        }
        .joined(separator: "\n")
}

/// The narrowing must not blind the wire it narrows.
@Test func lineCommentStrippingStillCountsRealCallSites() {
    let source = """
    // NSHomeDirectory() belongs in exactly one file.
    let home = URL(fileURLWithPath: NSHomeDirectory())  // and NSHomeDirectory() again
    /// Doc comment mentioning NSHomeDirectory() as well.
    """
    let stripped = strippingLineComments(source)
    #expect(stripped.components(separatedBy: "NSHomeDirectory()").count - 1 == 1)
    // The real call survived intact, not just the count.
    #expect(stripped.contains("URL(fileURLWithPath: NSHomeDirectory())"))
}

@Test func publisherSourceReferencesNoCredentialPath() throws {
    let forbidden = [
        ".env", "credentials", "secret", "password", "api_key", "apikey",
        "keychain", ".ssh", "id_rsa", ".netrc", "bws"
    ]
    let files = publisherSourceFiles()
    #expect(!files.isEmpty, "expected to find GradusMac source files to scan")

    for file in files {
        let contents = try String(contentsOf: file, encoding: .utf8)
        let lowered = contents.lowercased()
        for term in forbidden {
            #expect(
                !referencesForbiddenTerm(term, in: lowered),
                "\(file.lastPathComponent) references forbidden term '\(term)' (INV-7)"
            )
        }
    }
}

@Test func publisherFailureLogsTheSanitizedOperationName() throws {
    let source = try #require(
        publisherSourceFiles().first { $0.lastPathComponent == "GradusMacApp.swift" },
        "expected GradusMacApp.swift in the publisher source scan"
    )
    let contents = try String(contentsOf: source, encoding: .utf8)

    #expect(contents.contains("GradusLog.publish.warning("))
    #expect(contents.contains("PublishCoordinator.describe(error)"))
    #expect(!contents.contains("error.localizedDescription"))
}

/// The narrowing above must not become a hole: a real `.env` reference still
/// has to trip the wire in every position a filename can appear.
@Test func filenameTermNarrowingStillCatchesRealReferences() {
    #expect(referencesForbiddenTerm(".env", in: "let path = \"~/.env\""))
    #expect(referencesForbiddenTerm(".env", in: "open(\".env\")"))
    #expect(referencesForbiddenTerm(".env", in: "read .env"))
    #expect(referencesForbiddenTerm(".env", in: "a/.env/b"))
    #expect(referencesForbiddenTerm(".env", in: "trailing .env"))
    #expect(referencesForbiddenTerm(".ssh", in: "~/.ssh/id"))
    #expect(referencesForbiddenTerm(".netrc", in: "~/.netrc"))
    // ...and must not fire on identifiers that merely start the same way.
    #expect(!referencesForbiddenTerm(".env", in: "processinfo.environment"))
    #expect(!referencesForbiddenTerm(".env", in: "view.environmentobject(x)"))
    // Non-filename terms keep the original bare-substring behavior.
    #expect(referencesForbiddenTerm("secret", in: "let mysecretvalue = 1"))
    #expect(referencesForbiddenTerm("keychain", in: "keychainaccess"))
}

@Test func snapshotPathHasExactlyOneInjectionPoint() throws {
    // The snapshot path must be constructed in exactly one place
    // (PublishPipeline's defaultSnapshotPath) and threaded through
    // start(snapshotPath:) -- not recomputed or hardcoded elsewhere.
    let files = publisherSourceFiles()
    var occurrences: [(file: String, count: Int)] = []
    for file in files {
        let contents = try strippingLineComments(String(contentsOf: file, encoding: .utf8))
        let count = contents.components(separatedBy: "NSHomeDirectory()").count - 1
        if count > 0 {
            occurrences.append((file.lastPathComponent, count))
        }
    }
    #expect(
        occurrences.count == 1 && occurrences.first?.count == 1,
        "expected exactly one NSHomeDirectory() call site (PublishPipeline.defaultSnapshotPath), found: \(occurrences)"
    )
    #expect(occurrences.first?.file == "GradusMacApp.swift")
}
