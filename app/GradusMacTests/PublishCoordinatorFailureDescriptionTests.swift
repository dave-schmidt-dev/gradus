import CloudKit
import Foundation
import GradusKit
@testable import GradusMac
import Testing

// MARK: - Failure descriptions written to the log

/// `RELEASE_CHECKLIST.md` step 3 tells a reviewer to read these lines and act
/// on them, so the shape is a contract, not cosmetics.
///
/// The first version shipped `CKError.CKErrorCode(rawValue: 26) (26)` —
/// `CKError.Code` comes from an Objective-C `NS_ENUM` and has no case names to
/// interpolate, so the string carried the number twice and the meaning never.
@Test func failureDescriptionNamesTheCloudKitCode() {
    let described = PublishCoordinator.describe(.failure(CKError(.zoneNotFound)))
    #expect(described.contains("zoneNotFound"))
    // The number stays: it is the stable token to grep for and the only thing
    // that still says something when Apple adds a case this table lacks.
    #expect(described.contains("\(CKError.Code.zoneNotFound.rawValue)"))
    #expect(!described.contains("rawValue:"), "raw enum debug form leaked: \(described)")
}

/// A save can fail with something that is not a `CKError` at all — the
/// transport gives up, or `toCKRecord` hands back a Cocoa error. Falling
/// through to an empty or misleading string is how "it failed" becomes the
/// entire diagnosis.
@Test func failureDescriptionHandlesNonCloudKitErrorsAndMissingResults() {
    let cocoa = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil)
    let described = PublishCoordinator.describe(.failure(cocoa))
    #expect(described.contains("4"))
    #expect(described.contains(NSCocoaErrorDomain))

    // No entry for a record we asked CloudKit to save is its own failure mode,
    // and it is not the same as a failure with a code.
    #expect(PublishCoordinator.describe(nil).contains("no result"))
}

/// `RELEASE_CHECKLIST.md` tells a reviewer they may see `unmappedCKErrorCode`
/// and to look the number up rather than assume the publish path is broken, so
/// that string is a documented contract and not just a `default:` arm.
///
/// It is only reachable if a future SDK hands back a code this table predates.
/// `CKError.Code` is imported from an Objective-C `NS_ENUM` as a closed Swift
/// enum, so `init(rawValue:)` refuses anything outside the compiled cases —
/// which is exactly what this asserts. If a later SDK makes that construction
/// succeed, this test starts exercising the fallback for real instead of
/// silently passing on a premise that no longer holds.
@Test func unmappedCloudKitCodesCannotBeConstructedFromThisSDK() {
    let outsideTheEnum = CKError.Code(rawValue: 9999)
    if let outsideTheEnum {
        let described = PublishCoordinator.describe(.failure(CKError(outsideTheEnum)))
        #expect(described.contains("unmappedCKErrorCode"))
        #expect(described.contains("9999"))
    } else {
        #expect(outsideTheEnum == nil, "premise: the SDK rejects codes outside its own cases")
    }
}

/// Nothing from `userInfo` may reach the log. These records hold the user's
/// provider usage data, and `localizedDescription` is read straight out of the
/// same dictionary that carries them — which is why the description is built
/// from the code alone.
@Test func failureDescriptionDoesNotLeakTheRecordOrItsUserInfo() {
    let record = CKRecord(
        recordType: "ProviderStatus",
        recordID: CKRecord.ID(recordName: "Codex", zoneID: CKRecordZone.ID(zoneName: "GradusZone"))
    )
    record["secretish"] = "weekly_percent_left=3"
    let error = CKError(
        .serverRejectedRequest,
        userInfo: [
            NSLocalizedDescriptionKey: "rejected: weekly_percent_left=3",
            CKRecordChangedErrorServerRecordKey: record
        ]
    )

    let described = PublishCoordinator.describe(.failure(error))
    #expect(described.contains("serverRejectedRequest"))
    #expect(!described.contains("weekly_percent_left"))
    #expect(!described.contains("Codex"))
}
