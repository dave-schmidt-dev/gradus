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

Internal TestFlight candidate tests must cover the candidate ledger's allowed
transitions, digest/version predicates, fixture-only ASC pagination and strict
version policy, and redacted processing/compliance/assignment receipt predicates.
These checks prove local candidate safety only; they do not prove Apple upload,
processing, installability, or App Store submission.

The public release surface is intentionally two commands: `app/release-testflight`
for the candidate prepare/upload workflow and `app/release-status` for local
candidate status. The legacy `archive-upload-ios.sh` and `testflight-setup*`
entry points remain readable and runnable only as compatibility implementation
pieces; the candidate-bound bridge canary is now authorized.

`app/release-testflight --prepare-only` composes central `testflight` identity
freeze with the central `stage` command. `stage` admits only readiness, local
gate, production build, archive, signing, and artifact verification classes;
upload and every post-upload operation are excluded by contract.

Profile 2.0 is adopted for the verified candidate. The current canary result is
`adoption-authorized`; the fixed wrappers route through the central CLI and
remain fail-closed until the reviewed walkthrough and explicit upload handoff
are present. Local adapter and fixture checks do not replace upload, processing,
device, or user-visible TestFlight evidence.

`app/test_walkthrough.py` additionally proves that the dated release-owner
walkthrough is bound to the candidate's source revision, project/artifact
digests, version/build, and ledger record. It rejects missing route/control,
role, disabled/recovery, or system-sheet coverage. The walkthrough is a
TestFlight-only review artifact and does not replace device, account, or Apple
processing evidence.

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

1. the hermetic notarization and iOS-upload script tests (including inside-out
   nested signing, separate App Store profile verification, and version/build parity),
2. `swift test` over the **GradusKit** package (including atomic widget snapshot models),
3. `pytest` over the **Python producer** suite,
4. `xcodebuild test` for **GradusMac** (macOS), **GradusiOS** (pinned iPhone simulator),
   and **GradusWidget** (`GradusWidgetTests` unit and snapshot tests),
5. `xcodebuild test -only-testing:GradusiOSUITests` on the pinned **iPad**
   simulator.

Physical device acceptance requires adding and removing the small widget
(`systemSmall`) on hardware to verify system timeline reload and widget lifecycle,
as headless CI cannot fully substitute for system WidgetKit presentation.

Steps 2 and 3 are ordered before the simulator work so the gate fails fast, and
they cost ~8s cold / <1s warm against several minutes for the simulator half.

Step 5 exists because both size classes must be exercised (INV-12). iPhone and
iPad now render the same dense layout, differing only in column count and
whether each window row carries its reset time — so the interesting question is
no longer "can this destination reach the layout at all" but "does the layout
still behave when the adaptive column count resolves to more than one". Only
the iPad destination answers that. Only the UI-test bundle runs there;
rerunning the full iOS suite on a second simulator would roughly double the
gate's slowest phase to re-prove device-independent behavior.

`DensityLayoutXCUITests` deliberately does **not** skip by idiom. It did while
the dense grid was iPad-only, and that skip was the file's one soft spot: a
skipped test is green, so dropping the iPad destination would have left it
passing everywhere while executing nothing. Now that the layout is shared, the
test runs unskipped on both destinations, and the iPhone run is what proves the
compact path actually reaches the same layout rather than merely being
configured to.

This is the general rule, not a detail of one file: when a rule is supposed to
hold across size classes, assert it on every destination that can run it, and
reach for a skip only when a destination genuinely cannot. A skip is how two
platforms drift apart with the suite still green — which is precisely how the
iPhone kept a one-window-per-provider list for a full release after the iPad
stopped having one.

GradusKit needs its own step because it is consumed as a SwiftPM package
*dependency*: `xcodebuild test -scheme GradusMac|GradusiOS` builds its library
product but never its test targets, and XcodeGen cannot add them to a scheme's
`test:` block since they are not project targets. Without step 2 the package's
tests — the reconciliation core both apps import — do not run at all.

The `pre-push` hook invokes `bash app/test-gate.sh` with no filename narrowing
and propagates its exit status. This keeps the full cross-platform gate, rather
than a subset of Python tests, authoritative for pushes.

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
`GradusKitTests/SignalLevelTests.swift` and `tests/test_ui.py`. Percent
formatting does the same with `Fixtures/percent-format.json`, read by
`GradusKitTests/PercentFormatTests.swift` and `tests/test_ui.py`. Conventions:

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

Better still, where two predicates are meant to agree, **define one in terms
of the other** instead of asserting that two independent definitions match.
"Orange or worse" and "warns" were separate implementations that agreed for
every window carrying a pace and silently diverged for every window without
one, and the relationship test had a `guard` skipping exactly the rows where
they differed — so the suite documented the divergence rather than catching it.
`windowWarns` is now `signalLevel(...).needsAttention`, the guard is gone, and
the test asserts it covers at least one no-pace row so the skip cannot come
back. A relationship test is the right tool when two definitions genuinely must
stay separate; when they must not, one definition is stronger than any test.

The same applies to *aggregation*, which is easier to overlook because both
sides can use an identical per-item predicate and still disagree. The Mac asked
whether its worst-by-percentage window needed attention; iOS asked whether any
window did. Both called the same function. When a rule is "does this collection
need attention", pin the quantifier in one shared place —
`providerNeedsAttention` — and give it a test whose fixture answers differently
under `any` than under `worst`.

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
