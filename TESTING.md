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
is the authoritative local gate. It runs, in order:

1. the hermetic notarization and iOS-upload script tests,
2. `swift test` over the **GradusKit** package,
3. `pytest` over the **Python producer** suite,
4. `xcodebuild test` for **GradusMac** (macOS) and **GradusiOS** (pinned simulator).

Steps 2 and 3 are ordered before the simulator work so the gate fails fast, and
they cost ~8s cold / <1s warm against several minutes for the simulator half.

GradusKit needs its own step because it is consumed as a SwiftPM package
*dependency*: `xcodebuild test -scheme GradusMac|GradusiOS` builds its library
product but never its test targets, and XcodeGen cannot add them to a scheme's
`test:` block since they are not project targets. Without step 2 the package's
tests — the reconciliation core both apps import — do not run at all.

Note that `test-gate.sh` is **not** yet invoked by any git hook; `pre-push` runs
`pytest` only, so the Swift half is gated locally but not enforced on push.

## Cross-language rules: shared truth tables

Some rules must hold identically in Python and Swift — the usage signal ramp,
the warning predicate, pace arithmetic — and the two cannot share an
implementation. Mirroring them by hand and testing each side separately means a
one-sided edit passes both suites and ships as a rendering inconsistency
between the TUI and the apps.

Where a rule is mirrored, encode its input/output pairs as a JSON fixture that
**both** suites read, rather than writing the expectations twice. The signal
ramp does this with
`app/GradusKit/Tests/GradusKitTests/Fixtures/signal-levels.json`, read by
`GradusKitTests/SignalLevelTests.swift` and `tests/test_ui.py`. Conventions:

- The fixture lives inside the SwiftPM test target and is listed in
  `Package.swift`'s `resources:`. SwiftPM resources cannot reference files
  outside the target directory, so Python is the side that reads by relative
  path.
- Cover boundaries, not a dense matrix — each threshold from both sides, plus
  invalid and missing inputs. Give every case a `why` string; it becomes the
  assertion message on failure.
- Assert a minimum case count so a future edit cannot quietly delete coverage.
- Where two mirrored predicates are meant to agree (e.g. "orange or worse"
  and "warns"), assert the *relationship* over the table, not just each
  function in isolation.

A shared truth table catches drift; it does not prevent it. It is the interim
stand-in for real centralization — see the `[future]` row in `TASKS.md`.

## Rendering-level coverage for visual rules

When a rule changes *which* input decides a visual property, existing fixtures
are the thing most likely to hide a half-finished migration. Every iOS image
snapshot on the dashboard kept passing when the signal ramp moved from
percentage to pace, because each fixture happened to land on the same step
under both rules (62%/-0.05 is yellow either way; 4%/-0.30 and 0%/-0.30 are
red either way). The suite was green and the dashboard had *zero* coverage of
the change — it would have rendered identically had the call sites never been
migrated.

A passing snapshot suite after a rule change is therefore not evidence the
change reached the view. Add at least one fixture whose output **inverts**
under the old rule, and prefer inverting in both directions so a swap cannot
masquerade as correct: `dashboardColorsByPaceNotByPercentageRemaining` pairs
3%-left/on-pace (old red, new green) with 72%-left/burning-fast (old green,
new red). Keep such fixtures physically reachable — here `paceDelta ==
fractionLeft - fractionOfWindowRemaining` bounds pace to `>= fractionLeft - 1`,
so e.g. "85% left and critically behind" cannot occur and a fixture asserting
it would be testing an impossible state.

`tests/test_ui.py`'s `_capture` helper renders with `no_color=True`, so panel
tests built on it cannot observe style. A pure-function test plus a
`_capture` test can therefore both pass while the view calls the wrong
function entirely. When a change alters *which* style a row gets, add a test
that renders through `console.render()` and inspects `Segment.style` — see
`PaceRampRenderingTests`. The SwiftUI equivalent is a snapshot test, but
verify a snapshot diff before re-recording it: compare the ramp colors'
pixel counts rather than accepting the new image, so an unintended layout
shift is not baked into the baseline alongside the intended color change.
