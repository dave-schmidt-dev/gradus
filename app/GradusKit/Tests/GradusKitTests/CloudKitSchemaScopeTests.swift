import Foundation
@testable import GradusKit
import Testing

// The Mac publishes provider status and device presence into CloudKit and iOS
// reads it back. Both sides already go through one codec in
// `CloudKitMapping.swift`, and both derive their container, zone and record
// types from `CloudKitConstants` -- so the round-trip tests in
// `CloudKitMappingTests.swift` cover the encode/decode contract.
//
// What those tests cannot see is the failure that actually breaks the seam:
// one side spelling a schema name as a literal instead of reading the
// constant. Renaming `zoneName` would then move the producer and leave the
// consumer pointed at a zone nobody writes to, with every unit test still
// green because each side is internally consistent. This is a grep tripwire
// against that drift, in the same spirit as INV7Tests' credential-path scan.
//
// It found one real instance when it was written: `Shared/CloudKitSpike.swift`
// hardcoded all three names in DEBUG code compiled into both apps (that spike
// has since been retired).
//
// inv: INV-9 -- these names are the producer/consumer compatibility unit. The
// scan below stops a literal from drifting away from the constant; the pins
// stop the constant itself from drifting away from the deployed schema, which
// is a server-side migration for every installed client, not a refactor.

@Test
func deployedSchemaNamesAreNotRenamedByAccident() {
    // These four strings exist in CloudKit already. Changing one is a
    // migration -- old clients keep reading the old zone and record types --
    // so a rename must be a deliberate edit here, not a rename refactor that
    // compiles clean and ships silently.
    #expect(CloudKitConstants.containerIdentifier == "iCloud.com.zerodelta.gradus")
    #expect(CloudKitConstants.zoneName == "GradusZone")
    #expect(CloudKitConstants.recordType == "ProviderStatus")
    #expect(CloudKitConstants.devicePresenceRecordType == "DevicePresence")
    #expect(CloudKitConstants.devicePresenceSubscriptionID == "gradus-device-presence")
}

/// Names that define the wire schema. A literal spelling of any of these
/// outside the file that declares them is drift by construction.
private let schemaLiterals = [
    CloudKitConstants.containerIdentifier,
    CloudKitConstants.zoneName,
    CloudKitConstants.recordType,
    CloudKitConstants.devicePresenceRecordType
]

/// The one file allowed to spell them, because it is where they are declared.
private let declaringFileName = "CloudKitMapping.swift"

/// Test sources are excluded: a test may legitimately build a record with a
/// literal type to prove the decoder rejects or accepts it, and pinning those
/// to the constant would make the test restate the code under test.
private func isProductionSource(_ url: URL) -> Bool {
    let components = url.pathComponents
    let excludedDirectories: Set = [
        ".build", "build", "DerivedData", "release_candidate", "Pods", "Carthage"
    ]
    for component in components {
        if excludedDirectories.contains(component) {
            return false
        }
        if component.hasSuffix("Tests") {
            return false
        }
    }
    return url.pathExtension == "swift" && url.lastPathComponent != declaringFileName
}

/// `app/GradusKit/Tests/GradusKitTests/<this file>` -> `app/`.
private func appSourceRoot(filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
        .deletingLastPathComponent() // GradusKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // GradusKit
        .deletingLastPathComponent() // app
}

private func productionSwiftSources(root: URL) -> [URL] {
    guard
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter(isProductionSource)
}

/// A comment naming the zone is documentation, not a call site -- the same
/// false-positive class INV7Tests hit and narrowed. Code after `//` does not
/// run, so drift cannot hide there.
private func strippingLineComments(_ contents: String) -> String {
    contents
        .components(separatedBy: .newlines)
        .map { line -> Substring in
            guard let marker = line.range(of: "//") else { return line[...] }
            return line[line.startIndex ..< marker.lowerBound]
        }
        .joined(separator: "\n")
}

@Test func schemaNamesAreSpelledOnlyWhereTheyAreDeclared() throws {
    let root = appSourceRoot()
    let sources = productionSwiftSources(root: root)
    // Guard against the scan silently covering nothing: an empty sweep would
    // make every assertion below vacuously true.
    #expect(sources.count > 20, "expected to scan the app's production Swift sources under \(root.path)")

    for file in sources {
        let contents = try strippingLineComments(String(contentsOf: file, encoding: .utf8))
        for literal in schemaLiterals {
            #expect(
                !contents.contains("\"\(literal)\""),
                """
                \(file.lastPathComponent) spells the CloudKit schema name "\(literal)" as a literal. \
                Read it from CloudKitConstants instead, so renaming it moves the producer and the \
                consumer together.
                """
            )
        }
    }
}

/// The declaring file must stay reachable by the scan's own rule, or the
/// exemption above would be hiding a file that no longer exists.
@Test func theDeclaringFileIsTheOnlyExemption() {
    let mapping = appSourceRoot()
        .appendingPathComponent("GradusKit/Sources/GradusKit/\(declaringFileName)")
    #expect(FileManager.default.fileExists(atPath: mapping.path))
    #expect(!isProductionSource(mapping))
}

/// The narrowing must not blind the wire it narrows.
@Test func commentStrippingStillCatchesRealLiterals() {
    let source = """
    // The zone is named "GradusZone" for historical reasons.
    let zone = CKRecordZone(zoneName: "GradusZone")
    """
    let stripped = strippingLineComments(source)
    #expect(stripped.contains("\"GradusZone\""))
    #expect(stripped.components(separatedBy: "\"GradusZone\"").count - 1 == 1)
}

@Test func sourcesAreExcludedFromTheScan() {
    let root = appSourceRoot()
    #expect(!isProductionSource(root.appendingPathComponent("GradusiOSTests/DevicePresenceCloudTests.swift")))
    #expect(!isProductionSource(root.appendingPathComponent("GradusKit/.build/checkouts/x/Some.swift")))
    #expect(isProductionSource(root.appendingPathComponent("GradusiOS/CKZoneChangesFetcher.swift")))
}
