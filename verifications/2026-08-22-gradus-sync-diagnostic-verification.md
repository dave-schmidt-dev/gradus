# GradusMac publish diagnostic — independent verification

Scope: `app/GradusMac/GradusMacApp.swift`, `app/GradusMac/PublishCoordinator+ErrorNaming.swift`,
`app/GradusMacTests/PublishCoordinatorFailureDescriptionTests.swift`, plus
`app/GradusMac/PublishCoordinator.swift`, `app/GradusMac/GradusLog.swift` (pulled in because the
artefacts reference them directly).

## Task 1 — Safe description support for operation-level errors

**Requirements check.** `PublishCoordinator.describe(_ error: Error)` at
`app/GradusMac/PublishCoordinator+ErrorNaming.swift:20-26` builds its string from `CKError.code`
only (mapped through a static `[CKError.Code: String]` table, `:40-76`) or, for non-`CKError`
values, from `NSError.code`/`.domain` (`:22-23`). Neither branch touches `userInfo` or
`localizedDescription`. This is additive to the existing `describe(_ result:)` overload
(`:11-15`), which already handled per-record failures — the new overload is what task 2 calls at
the operation boundary.

**Clean-room verification.** Traced both branches by hand: `CKError.Code` (line 25) only reads
`.rawValue`, an `Int`; the NSError branch (line 23) only reads `.code`/`.domain`, both scalar/String
fields uninvolved with `userInfo`. No path in this file constructs or forwards a string that
originated in a CloudKit record.

**Blind-spot discovery.** `T17SeamGate.swift:58,76,105,116` (a `DEBUG`-only, `--t1-7-gate`
developer console gate, not the shipping failure path) still does raw `\(error)` interpolation to
`print()`. Out of scope per the task's resource limits and not part of the log file the release
checklist reads, but flagging it since it's the one sibling error-printing site in the same file
family that doesn't use `describe`.

## Task 2 — Logging the safe description at the operation failure boundary

**Requirements check.** `GradusMacApp.swift:305-326` is the single call site for
`coordinator.upsert(statuses)` in production. Its `catch` block logs
`GradusLog.publish.warning("cloud sync failed (operation \(operationID), error \(PublishCoordinator.describe(error)))")`
(`:322-324`) using the new `describe(_ error:)` overload, then unconditionally calls
`await viewModel.cloudSyncDidFail(operationID: operationID)` (`:325`).

**Correction from first pass:** `PublisherViewModel.cloudSyncDidFail(operationID:)`
(`PublisherViewModel.swift:221-225`) is not an unrelated sibling — it sits directly downstream of
the same catch, and its body logs a second `GradusLog.publish.warning("cloud sync failed
(operation \(operationID))")` (`:223`) with no error detail. So every operation-level failure now
writes **two** `publish`-category warning lines: the new one carrying the safe error code, then an
older, less specific one carrying only the operation number. Neither leaks anything — line 223 is
prior, unmodified code and interpolates only the `UInt64` operation ID — but a reviewer grepping
the log for one failure will see it duplicated. Not a safety defect; a minor logging-hygiene gap
this task didn't need to fix but is worth naming since the release checklist expects one line per
event.

**Clean-room verification.** The full interpolated line at `:322-324` has two dynamic values:
`operationID` (`UInt64`, sourced from `PublisherViewModel.cloudSyncDidStart()` at
`PublisherViewModel.swift:205-210`, a monotonic counter with no payload content) and
`PublishCoordinator.describe(error)`. Both are scalar/derived-safe. `GradusLog.swift:122` uses
explicit `privacy: .public`, so this safe string actually renders in `log show` output rather than
being redacted to `<private>` — the mechanism this change relies on to be useful is itself
functioning.

**Blind-spot discovery.** `PublishCoordinator.swift:108-110` — the pre-existing per-record log
line — already used `Self.describe(outcome.results[recordID])`, i.e. the `Result`-taking overload;
no gap there. Separately, the `do` block this catch guards is not limited to `coordinator.upsert`:
`try payload.providers.map { try makeProviderStatus(...) }` (`GradusMacApp.swift:308-315`) throws
into the same `catch`. `makeProviderStatus` (`SnapshotDataValidation.swift:75-96`) throws
`SnapshotDataValidationError` (`SnapshotDataValidation.swift:9-15`), whose cases carry associated
`String` payloads (e.g. `.unsupportedKey(String)`) that *could* echo snapshot content. `describe`'s
non-`CKError` branch, however, only ever reads `(error as NSError).code`/`.domain` — Swift-enum
bridging maps those to the case ordinal and the mangled type name, not the associated value — so
this throw site is still safe under the current `describe` implementation, but it was not one of
the artefacts and deserves explicit note as an in-scope path this report is now verifying.

## Task 3 — Swift Testing coverage that record metadata is not reflected

**Requirements check.** `PublishCoordinatorFailureDescriptionTests.swift:41-52`
(`failureDescriptionHandlesOperationLevelCloudKitErrors`) asserts the exact string
`"zoneNotFound (CKError \(...))"` and that neither `weekly_percent_left` nor
`error.localizedDescription` appear, against a `CKError` built with a poisoned
`NSLocalizedDescriptionKey`. `:79-97`
(`failureDescriptionDoesNotLeakTheRecordOrItsUserInfo`) goes further: builds a real `CKRecord`
with a `"secretish"` field, embeds it via `CKRecordChangedErrorServerRecordKey`, and asserts the
record's field value and its ID (`"Codex"`) do not appear in the output.

**Clean-room verification (would-fail check).** Reasoned through the counterfactual rather than
mutating source: if `describe(_ error:)` were changed to use `ckError.localizedDescription` or to
interpolate the error directly, the exact-string assertion at `:49` and the leak-freedom
assertions at `:50-51` and `:95-96` would all fail, since `localizedDescription` is documented to
read from the same `userInfo` these tests poison. This is corroborated by the code comment at
`PublishCoordinator+ErrorNaming.swift:36-39` explaining exactly this hazard was the reason to hand
name the codes instead. Coverage is real, not tautological.

**Blind-spot discovery.** `unmappedCloudKitCodesCannotBeConstructedFromThisSDK` (`:64-73`) is
conditionally vacuous on the current SDK (`CKError.Code(rawValue: 9999)` returns `nil` today, so
the `else` branch's `#expect(outsideTheEnum == nil, ...)` is what actually runs) — this is
documented in the test's own comment as intentional, self-flagging premise, not a hidden gap.
Separately, the file-header comment (`:9-14`) and `RELEASE_CHECKLIST.md:146-155` were checked: the
checklist does document the per-record line (`save failed for <provider>: <code name> (CKError
<number>)`) and the `unmappedCKErrorCode` fallback as a real reviewer-facing contract, matching the
tests' stated rationale. It does **not** yet mention the new operation-level line
(`"cloud sync failed (operation N, error ...)"`) this task added — `grep` for `"cloud sync
failed"` in that file returns nothing. Not a safety gap (the format is self-explanatory and
follows the same code-name convention), but the checklist wasn't extended to describe it.

## Spot-checks

1. **No localized/userInfo leakage on failure paths** — confirmed above (Task 1/3), including both
   dynamic values in the new log line (`operationID`, `describe(error)`) and the second throw site
   feeding the same catch (`makeProviderStatus`, Task 2 blind-spot). No path reaching
   `GradusLog.publish` in or downstream of this change touches `userInfo` or `localizedDescription`.
2. **Test would fail without the behavior** — confirmed by counterfactual reasoning above (Task 3);
   not executed by mutating source, since that would leave the tree dirty for a read-only
   verification pass.
3. **Retry/failure semantics unchanged** — confirmed: `GradusMacApp.swift`'s `catch` block control
   flow (call `cloudSyncDidFail`, no rethrow, no new retry) is identical except for the added log
   interpolation. `PublishCoordinator.swift`'s retry logic (`retryServerRecordChanged`,
   `retryWithBackoff`) is untouched by this diff — `describe` is read-only and has no side effects.
4. **Focused verification run** — attempted `xcodebuild test -only-testing:GradusMacTests/PublishCoordinatorFailureDescriptionTests`
   (scheme `GradusMac`, `CODE_SIGNING_ALLOWED=NO`, no CloudKit network involved since the test only
   exercises pure functions against locally constructed `CKError`/`CKRecord` values) and a scoped
   `swiftlint lint` on the three artefacts. Both were blocked by this session's Bash permission
   layer (`"This command requires approval"`, no interactive approval available in this run) —
   confirmed via a plain `echo` control that basic Bash execution itself works, so the block is
   specific to `xcodebuild`/`swiftlint`, not the tool generally. Substituted static verification:
   confirmed `PublishCoordinatorFailureDescriptionTests.swift` and
   `PublishCoordinator+ErrorNaming.swift` are both wired into the `GradusMac`/`GradusMacTests`
   build phases in `Gradus.xcodeproj/project.pbxproj` (lines 83/116/367/399/730/826/1311/1435), so
   the new test is not orphaned from the counted gate `app/test-gate.sh` runs on push.

## Verdict

Evidence class: verified by full-file reading and manual code tracing across the three artefacts
plus their direct callers/callees (`PublishCoordinator.swift`, `PublisherViewModel.swift`,
`GradusLog.swift`, `SnapshotDataValidation.swift`); no test execution or build ran — `xcodebuild
test -only-testing:...` and `swiftlint lint` were both attempted and blocked by this session's Bash
approval layer (confirmed non-generic via a plain `echo` control), so pbxproj build-membership was
used as a substitute, not a stand-in for a green gate.

Within that evidence class: both tasks meet the safety requirement. Every path that can reach
`GradusLog.publish` from this change — `describe(_ error:)`'s two branches, the `operationID`
value, and the newly-identified `makeProviderStatus` throw site sharing the same `catch` — stays
free of CloudKit `userInfo`/`localizedDescription` and free of snapshot payload content. The tests
provide real, non-tautological coverage (verified by counterfactual reasoning, not execution). No
regression in publish/retry control flow.

Two non-blocking findings, neither a safety issue: (1) every operation-level failure now writes
**two** `publish` warning lines — this task's new one with the error code, plus the pre-existing
`PublisherViewModel.cloudSyncDidFail` one without — since the latter sits downstream of the same
catch and wasn't touched by this change; a release-checklist reader will see duplicated entries per
failure. (2) `RELEASE_CHECKLIST.md` documents the per-record failure line but was not extended to
describe the new operation-level line's format. `T17SeamGate.swift`'s DEBUG-only developer gate
still uses raw error interpolation, out of scope and not the production log path.
