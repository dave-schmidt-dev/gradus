# Gradus automated testing standard

Every new feature and every new user-facing UI element must have automated
regression coverage before it can pass the release gate. Tests are part of the
feature's implementation, not a follow-up task.

## Required test layers

Use the lowest layer that proves the behavior, adding higher-fidelity coverage
when the user interaction or platform boundary requires it:

| Change | Required coverage |
| --- | --- |
| Pure logic, parsing, mapping, sorting, or state transition | Swift Testing/XCTest or Python unit/property test |
| Mac/iOS producer-consumer contract | Producer mapping test, consumer decoding/reconciliation test, and a shared fixture or integration assertion |
| New SwiftUI view or visual state | Snapshot test for relevant light/dark and state variants |
| New interactive control or user workflow | XCUITest/XCUIAutomation test that launches the app and performs the workflow through accessibility-visible controls |
| Existing bug or crash regression | A test that fails on the old behavior and passes on the fix |

Snapshot tests do not replace behavior tests for tappable controls. UI tests do
not replace unit tests for pure logic. New interactive controls must expose
stable accessibility labels or identifiers so the UI test does not depend on
visual coordinates or incidental text layout.

## Release requirements

- Add the test to the correct Xcode target or Python test runner in the same
  change as the feature.
- Ensure the test is discovered by `app/test-gate.sh`; an unregistered test
  file is not coverage.
- Run the targeted test while developing, then run the full cross-platform
  gate before release.
- Cover both success and meaningful failure/empty states for new sync or
  provider behavior.
- A manual-only check is an exception, not a substitute. Use one only when
  the behavior requires a physical device, Apple-account state, push delivery,
  or another boundary the automation cannot control; document the reason,
  exact steps, and follow-up in `HISTORY.md`/`TASKS.md`.

Gradus currently uses Swift Testing/XCTest for logic, XCUITest for iOS user
flows, and swift-snapshot-testing for visual regression. `app/test-gate.sh`
is the authoritative local gate for the Mac and iOS targets.
