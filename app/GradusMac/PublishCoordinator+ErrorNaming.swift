import CloudKit
import Foundation

extension PublishCoordinator {
    /// Describes a save result for the log by error *code*, not by dumping the
    /// error whole. A `CKError`'s `userInfo` can carry the offending record and
    /// its fields, and these records hold the user's provider usage data —
    /// there is no reason for any of it to reach a log file to explain why a
    /// save failed. That rules out `localizedDescription` too: it is read out
    /// of the same `userInfo` and can carry server-supplied text.
    static func describe(_ result: Result<CKRecord, Error>?) -> String {
        guard let result else { return "no result returned for this record" }
        guard case let .failure(error) = result else { return "success" }
        guard let ckError = error as? CKError else {
            let nsError = error as NSError
            return "\(type(of: error)) (code \(nsError.code), domain \(nsError.domain))"
        }
        return "\(name(for: ckError.code)) (CKError \(ckError.code.rawValue))"
    }

    /// `CKError.Code` is imported from an Objective-C `NS_ENUM`, so it has no
    /// synthesized case names: interpolating it yields
    /// `CKErrorCode(rawValue: 26)` — the number twice and the name never. The
    /// first release-checklist line this ever produced read
    /// `save failed for B: CKError.CKErrorCode(rawValue: 26) (26)`, which
    /// tells a reader at 2am to go look up 26 rather than telling them the
    /// zone is gone.
    ///
    /// Spelled out rather than derived, because the alternative that needs no
    /// table is `localizedDescription`, and that reaches into the `userInfo`
    /// this function exists to stay out of. An unmapped code still prints its
    /// number: honest, and one line short of ideal, rather than wrong.
    private static let codeNames: [CKError.Code: String] = [
        .internalError: "internalError",
        .partialFailure: "partialFailure",
        .networkUnavailable: "networkUnavailable",
        .networkFailure: "networkFailure",
        .badContainer: "badContainer",
        .serviceUnavailable: "serviceUnavailable",
        .requestRateLimited: "requestRateLimited",
        .missingEntitlement: "missingEntitlement",
        .notAuthenticated: "notAuthenticated",
        .permissionFailure: "permissionFailure",
        .unknownItem: "unknownItem",
        .invalidArguments: "invalidArguments",
        .serverRecordChanged: "serverRecordChanged",
        .serverRejectedRequest: "serverRejectedRequest",
        .assetFileNotFound: "assetFileNotFound",
        .assetFileModified: "assetFileModified",
        .incompatibleVersion: "incompatibleVersion",
        .constraintViolation: "constraintViolation",
        .operationCancelled: "operationCancelled",
        .changeTokenExpired: "changeTokenExpired",
        .batchRequestFailed: "batchRequestFailed",
        .zoneBusy: "zoneBusy",
        .badDatabase: "badDatabase",
        .quotaExceeded: "quotaExceeded",
        .zoneNotFound: "zoneNotFound",
        .limitExceeded: "limitExceeded",
        .userDeletedZone: "userDeletedZone",
        .tooManyParticipants: "tooManyParticipants",
        .alreadyShared: "alreadyShared",
        .referenceViolation: "referenceViolation",
        .managedAccountRestricted: "managedAccountRestricted",
        .participantMayNeedVerification: "participantMayNeedVerification",
        .serverResponseLost: "serverResponseLost",
        .assetNotAvailable: "assetNotAvailable",
        .accountTemporarilyUnavailable: "accountTemporarilyUnavailable"
    ]

    private static func name(for code: CKError.Code) -> String {
        codeNames[code] ?? "unmappedCKErrorCode"
    }
}
