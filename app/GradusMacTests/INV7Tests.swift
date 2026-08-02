import Foundation
import Testing

// INV-7: "The CloudKit publisher takes its snapshot data through a single
// injected snapshot-path dependency, and its source references no
// credential path." This is a grep tripwire (PW, plan §8/§7) -- it catches
// obvious drift (a new hardcoded path, a stray credential string) but is
// not a proof; PM-15's fs_usage runtime canary check is deferred
// beta-hardening, not this gate.

private func publisherSourceFiles() -> [URL] {
    let thisFile = URL(fileURLWithPath: #filePath)
    let gradusMacDir = thisFile
        .deletingLastPathComponent()  // GradusMacTests/
        .deletingLastPathComponent()  // app/
        .appendingPathComponent("GradusMac")
    guard
        let enumerator = FileManager.default.enumerator(
            at: gradusMacDir, includingPropertiesForKeys: nil)
    else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

@Test func publisherSourceReferencesNoCredentialPath() throws {
    let forbidden = [
        ".env", "credentials", "secret", "password", "api_key", "apikey",
        "keychain", ".ssh", "id_rsa", ".netrc", "bws",
    ]
    let files = publisherSourceFiles()
    #expect(!files.isEmpty, "expected to find GradusMac source files to scan")

    for file in files {
        let contents = try String(contentsOf: file, encoding: .utf8)
        let lowered = contents.lowercased()
        for term in forbidden {
            #expect(
                !lowered.contains(term),
                "\(file.lastPathComponent) references forbidden term '\(term)' (INV-7)"
            )
        }
    }
}

@Test func snapshotPathHasExactlyOneInjectionPoint() throws {
    // The snapshot path must be constructed in exactly one place
    // (PublishPipeline's defaultSnapshotPath) and threaded through
    // start(snapshotPath:) -- not recomputed or hardcoded elsewhere.
    let files = publisherSourceFiles()
    var occurrences: [(file: String, count: Int)] = []
    for file in files {
        let contents = try String(contentsOf: file, encoding: .utf8)
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
