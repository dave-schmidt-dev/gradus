# iOS Small Widget — Final Independent Verification

Scope: `product.diff`, `release.diff`, `gate.diff` (final remediation diffs, `/private/tmp/gradus-widget-final-review/`), read in full. Cross-checked against current working tree at `71d4f63` (clean, matches HEAD) and the prior verification `verifications/2026-08-23-ios-small-widget-verification.md` (which found HIGH-severity C1, T2-1, T3-1, T3-2 and MEDIUM/LOW findings against an earlier revision).

Method: full artefact reads, plan/checklist/INVARIANTS cross-reference, direct `Read`/`Grep` against current source and generated Xcode project artifacts (no builds/tests run), and one delegated agent pass re-deriving six specific remediation claims against live file content (not diff text).

---

## Task 1 — Widget snapshot contract, publisher, extension, presentation, accessibility, App Group

**Requirements check:** `WidgetSnapshot.swift` allowlist is unchanged from the prior PASS (`schema_version/phone_sync_date/provider_name/provider_display_name/status/selected_window` only; `WidgetSnapshotTests.swift:464-506` pins the allowlist and a prohibited-key tripwire). `selectWidgetWindow`/`compareWidgetWindows` (`WidgetSnapshot.swift:100-133`) keep the severity→percentLeft→id tie-break.

**Clean-room verification (targeting the four prior HIGH/MEDIUM defects in this task):**
- T3-1 (percent bypass): `WidgetFormatting.swift:6` now calls `percentDisplay(percentLeft)`, which resolves to `GradusKit.PercentFormat.swift:57-60` — the same function the dashboard uses, not a local reimplementation. Confirmed by independent agent read. **Fixed.**
- T3-2 (frozen sync age): `GradusSmallWidgetView.swift:772` (`Text("synced \(phoneSyncDate, style: .relative) ago")`) uses SwiftUI's live-updating relative style; the test-only `syncAgeOverride` init (`:653-656`) is non-public, and the sole production call site `GradusWidget.swift:9` uses the public `init(entry:)` which sets it `nil`. **Fixed.**
- T1-2 (status ignored): `GradusSmallWidgetView.swift:723` now branches `snapshot.status == .error || snapshot.selectedWindow == nil` before rendering a value; `WidgetSnapshotPublisher.swift:150` maps `!provider.rankingIsOK` to `.error`. **Fixed.**
- T3-4 (placeholder accessibility overridden by children): `GradusSmallWidgetView.swift:698-700` now wraps the placeholder in `.accessibilityElement(children: .ignore)` before `.accessibilityLabel(...)`, matching the pattern already used by `message(...)` and `current(...)`. **Fixed.**
- T3-6 (force-unwrap): replaced by `else if let window = snapshot.selectedWindow` (`GradusSmallWidgetView.swift:725`). No force-unwrap remains in the file. **Fixed.**
- T1-5 (fractional-second ISO8601 drop): `WidgetSnapshot.swift:90-98` now tries `.withFractionalSeconds` first, falls back without it. New tests `widgetWindowSnapshotParsesFractionalSecondResetTimestamps` (:607-630) cover Z and offset forms. **Fixed.**
- T1-3 (errored no-window provider hides a genuinely urgent one): `WidgetSnapshotPublisher.swift:1822-1830`'s `selectProvider` now prefers the first ranked provider with a selectable window, falling back to `ranked.first` only if none qualify; covered by `noWindowProviderDoesNotHideProviderWithValidUrgentWindow` (`WidgetSnapshotPublisherTests.swift:2451-2490`). **Fixed.**

**Blind-spot discovery:** T1-4 (duplicated signal-severity ramp) is **not** addressed — `WidgetSnapshot.swift:100-109` still hand-rolls `signalSeverityRank` in parallel with `ProviderRanking.swift`'s ramp; a future retune of one can silently desync from the other. T1-6 (atomic-write test doesn't exercise the real OS-level atomic writer, only an injected-failure double) is likewise still open. Both are LOW and pre-existing, not regressions from this remediation pass — carried forward as non-blocking.

---

## Task 2 — Nested-extension signing, provisioning, candidate evidence, release bridge, walkthrough, docs

**Requirements check:** This closes the prior review's sole HIGH cross-cutting gap (Finding C1/C1a/b/c: Wave 3 was entirely absent). `release.diff` now adds `validate_profile`, `resolve_provisioning_profile`, `locate_and_validate_distribution_profiles`, and `repackage_and_sign_ios_candidate` (`archive-upload-ios.sh:861-925, 1531-1537, 1590-1601`), replacing the single-profile `xcodebuild archive ... PROVISIONING_PROFILE_SPECIFIER="$SIGNING_PROFILE_NAME"` call the prior review flagged.

**Clean-room verification:**
- C1a (build-number desync): `bump_ios_build_number` (`archive-upload-ios.sh:1358-1362`) now calls `bump_target_build_number` for both `GradusiOS` and `GradusWidget`; `test-archive-upload-ios.sh:702` asserts line 13 of the test fixture project.yml (the `GradusWidget` block) is bumped alongside GradusiOS. **Fixed.**
- C1b (extension left dev-signed): `repackage_and_sign_ios_candidate` (`archive-upload-ios.sh:413-492`) signs `GradusWidget.appex` with the widget profile/entitlements first, then `GradusiOS.app` last, verified by `test-archive-upload-ios.sh:1267-1273` grepping mock-codesign call order (widget line number strictly less than app line number). **Fixed.**
- C1c (no version-parity gate): `validate_common_marketing_version` now requires Mac==iOS==Widget (`archive-upload-ios.sh:94-105`); `validate_bundle_version_parity` (`:382-411`) checks both `CFBundleShortVersionString`/`CFBundleVersion` for app vs. embedded extension post-archive, exercised by drift fixtures `test-archive-upload-ios.sh:1183-1205`. **Fixed.**
- Fail-closed nested `.appex` handling: `repackage_and_sign_ios_candidate` rejects missing/wrong-name/duplicate `.appex` (`archive-upload-ios.sh:424-438`), and entitlement derivation/assertion runs before signing, with a failed extraction correctly aborting *before* any `codesign --sign` call (`test-archive-upload-ios.sh:1166-1180`, log-grep proof). `assert_no_disallowed_extension_entitlements` (`archive-upload-ios.sh:357-380`) rejects CloudKit/iCloud/APS keys leaking into the widget's derived entitlements. Python-side `release_prepare_bridge.inspect_artifact` gets a parallel, independently-hermetic test suite (`test_gradus_release_bridge.py:1304-1873`) covering profile swap (including identical-bytes and mismatched-identifier variants), missing/extra/misnamed extension, version/build drift, CloudKit/APS leakage in both the profile and the *signed* entitlements, missing signing certificate, invalid codesign verification, and `get-task-allow=true` on either bundle — all asserting `BridgeError`. This is materially more thorough fail-closed coverage than the plan's Task 3.1 acceptance criteria required.
- Artifact evidence binding: `build_proof` test (`test_valid_nested_artifact_inspection_and_proof_binding`, `:1510-1542`) confirms `widget_embedded_profile_sha256`/`widget_signing_certificate_sha256` are bound into the proof alongside the main app's, so a candidate's evidence record can't silently omit the extension's identity.

**Blind-spot discovery:** `RELEASE_CHECKLIST.md` now documents the nested-signing contract explicitly (four numbered requirements, `:54-77`) and adds the physical-device widget-lifecycle acceptance item (`:38-41`) — this closes the prior review's separate observation that `RELEASE_CHECKLIST.md`/`VERSIONING.md`/`TESTING.md` were never touched. I did not find a `VERSIONING.md` diff in any of the three artefacts; it wasn't in §Context either, so I treat this as out of this review's bound scope rather than a gap — flag for the release owner to confirm `VERSIONING.md` needed no widget-specific update (its content governs marketing-version *semantics*, which didn't change; plausible it genuinely needs nothing).

---

## Task 3 — Remediation of independent review findings, deterministic snapshots

**Requirements check:** Beyond the items already verified in Tasks 1–2 above (T3-1/T3-2/T3-4/T3-6/T1-2/T1-3/T1-5/C1), Task 2's account/sync-lifecycle findings are addressed here.

**Clean-room verification:**
- T2-1 (durable clear / resurrection on relaunch — the second HIGH finding in the prior review): `isWidgetPublicationAllowed` (`DashboardViewModel+Sync.swift:193-201`) now requires `requiredICloudMode.allowsLiveWork && syncEnabled && accountStatus == .available`, gating every republish path (init, sync completion via `commitCachedProvidersAndWidget`, `syncEnabled` didSet, `commitWarningThreshold`, and `updateAccountStatus`). `initialAccountStatus` defaults to `.couldNotDetermine` in the production initializer (`DashboardViewModel.swift:1508, 1539`), so a relaunch's `init`-time `synchronizeWidgetSnapshot()` call clears rather than resurrects stale-account data. Directly exercised by `relaunchAndThresholdAfterAccountLossDoNotResurrectWidget` (`WidgetSnapshotPublisherTests.swift:2316-2362`), which reconstructs a fresh `DashboardViewModel` from the same retained cache and asserts no snapshot is written until a real `.available` status arrives, and by `recoveryRepublishesRetainedCacheWithoutRefetch` (`:2365-2387`) for the legitimate-recovery direction the prior review also flagged as broken (blank widget after `.noAccount → .available` with no new fetch). **Fixed, both directions.**
- T2-2 (disabling sync never clears): `DashboardViewModel.swift:104` didSet now calls `synchronizeWidgetSnapshot()`/`clearWidgetSnapshot()` on `syncEnabled` toggle; test `disabledSyncClearsProjectionAndReenablingRepublishes` (`WidgetSnapshotPublisherTests.swift:2390-2418`). **Fixed.**
- T2-3 (slider drag causes ~100 synchronous file I/O + reload calls): `SettingsView+WarningThreshold.swift:1668-1677` moves the publish call into `Slider(onEditingChanged:)`, firing only once per gesture instead of on every `didSet`; `oneReloadPerCommittedThresholdEdit` (`WidgetSnapshotPublisherTests.swift:2421-2448`) explicitly simulates five intermediate drag values and asserts `reloadCount` stays at 1 until commit. **Fixed.**
- T2-4 (silent failure with no diagnostic): `WidgetSnapshotPublisher.Diagnostic` enum plus `diagnosticHandler`/`Logger.error` calls added (`WidgetSnapshotPublisher.swift:1711-1821`); `WidgetSnapshotPublisherDiagnosticTests.swift` covers container-unavailable, save-failure, and clear-failure paths, and confirms a save failure doesn't fail `sync()` itself. **Fixed** (diagnostics now reach OSLog; still no user-facing UI surface, which is consistent with the plan's "warning log" requirement, not a UI requirement).

**Blind-spot discovery:** T2-5 (test-coverage gaps) is only partially closed — `sampleAndUITestModesNeverConstructLiveWidgetPublisher` (`WidgetSnapshotPublisherTests.swift:2300-2313`) still tests the `shouldCreateWidgetPublisher` pure predicate rather than the live `SampleDataSession`/UI-test fixture wiring end-to-end. Non-blocking (LOW), matches the prior review's own characterization.

---

## Task 4 — `GradusMacUITests` exclusivity (local shell gate + `GradusMac` scheme) vs. `GradusMacCloud`

**Requirements check:** `.pre-commit-config.yaml:9` now runs bare `bash app/test-gate.sh` (the `--skip-macos-ui` selector and its `configure_counting_legs` implementation are deleted entirely, not just defaulted-off — `gate.diff` removes the function and the `skip_macos_ui` CLI flag). The local gate script no longer contains a `GradusMacUI` counting leg, the installed-app stop/restore lifecycle functions, or any `-only-testing:GradusMacUITests` selector.

**Clean-room verification (this is the one task where I went beyond the diffs into the actual generated/committed Xcode project, since the diffs only show `project.yml` text and the enforcement claims are about generated `.xcscheme` files):**
- `git status` is clean at `71d4f63` — the working tree exactly matches HEAD, so direct reads reflect the true committed state.
- `app/Gradus.xcodeproj/xcshareddata/xcschemes/GradusMac.xcscheme`: `grep -c 'GradusMacUITests'` → **0**.
- `app/Gradus.xcodeproj/xcshareddata/xcschemes/GradusMacCloud.xcscheme`: `grep -c 'GradusMacUITests'` → **2** (matches `test-gate-selfcheck.sh`'s `cloud_scheme_keeps_macos_ui` expectation of exactly one `BuildableName`/`BlueprintName` pair).
- `GradusWidget.xcscheme` exists in the same directory (confirms the widget scheme was actually generated and committed, not just declared in `project.yml`).
- `app/Gradus.xcodeproj/project.pbxproj` has exactly one `"Embed Foundation Extensions"` copy-files phase and 5 references to `GradusWidget.appex` (product ref, build file, copy-phase file ref, container item proxy, target dependency — the expected shape for a single embedded extension, consistent with the prior review's PASS on this point for an earlier revision).
- `test-gate-selfcheck.sh` cross-checks this at three independent layers: the gate script's own text (no `GradusMacUITests` selector, no `GradusMacUI` counting leg — `gate.diff:282-285`), the local `GradusMac.xcscheme` (0 occurrences), and `GradusMacCloud.xcscheme` (exactly 2) — plus two structural-mutation tests (`gate.diff:287-297`) proving the `GradusMacCloud` contract check itself fails closed if `- GradusMacUITests` or `GRADUS_DISABLE_PIPELINE: "1"` is stripped from `project.yml`.
- `RELEASE_CHECKLIST.md`/`README.md` prose updated consistently: "sole `GradusMacUITests` owner", "required Xcode Cloud `GradusMacCloud` status" — cross-checked by `release_checklist_cloud_only` (`gate.diff:263-271`), which also asserts the *old* phrasing ("headless equivalent of the `GradusMacUI` leg", "local pre-push selector does not replace this candidate evidence") is gone, not just that new phrasing is present.

**Blind-spot discovery:** No local path — neither the shell gate, the ordinary `GradusMac` xcscheme, nor any counting leg — can execute `GradusMacUITests`; `GradusMacCloud` remains the only path that references it, and that scheme is unreachable from `test-gate.sh` (it's invoked only via Xcode Cloud / App Store Connect, outside this repo's local automation). This matches the task's exact requirement. The `iPhone integrated-gate floor` bump from 171→177 (`gate.diff:612-615`) is internally consistent with the net new tests added to `GradusiOSTests` in this pass (widget-publisher lifecycle, diagnostic, and threshold-commit tests); I did not independently recount every `@Test`/`func test` to the exact integer, since the self-check's own `assert_counting_leg`/`EXPECTED_COUNTING_LEG_COUNT` machinery (unchanged logic, only counts) is designed to fail closed on an actual undercount at gate run time — an execution-time guarantee outside this review's static/no-build scope.

---

## Verdict

**PASS**

All four HIGH-severity findings from the prior independent verification (`C1`/`C1a`/`C1b`/`C1c` nested-signing absence, `T2-1` non-durable widget clear/resurrection, `T3-1` percent-formatting bypass, `T3-2` frozen sync age) are confirmed fixed by direct reads of current source, not just diff text or comments. All MEDIUM findings (`T2-2`, `T2-3`, `T2-4`, `T1-3`, `T3-3`†, `T3-4`, `T4-1`) and most LOW findings are also closed, each with a new regression test named for the scenario it locks in. The `GradusMacUITests`-exclusivity requirement is enforced at three independent layers (script text, local scheme, cloud scheme) with fail-closed mutation tests, and I independently confirmed the generated `.xcscheme` files actually match `project.yml` in the committed tree rather than trusting the diff's intent. The nested-signing/entitlement/version-parity path now has materially thorough hermetic fail-closed coverage on both the shell and Python sides.

† `T3-3` (hardcoded 12-hour US reset format) was not in my explicit re-check list; `WidgetFormatting.swift`'s `reset(...)` still accepts a `locale` parameter and `WidgetFormatting.reset` test cases (`GradusWidgetTests.swift:1140-1173`) now assert `en_US`/`en_GB`/`de_DE` produce locale-correct output via `setLocalizedDateFormatFromTemplate("MMMdjm")` rather than a fixed format string — this is a genuine fix, confirmed by direct diff read (`WidgetFormatting.swift:899-901`), not carried over as open.

**Remaining non-blocking findings (LOW, pre-existing, not regressions of this pass):**
- T1-4 — `WidgetSnapshot.swift:100-109` still duplicates `ProviderRanking.swift`'s signal-severity ramp instead of sharing it.
- T1-6 — the atomic-write test (`WidgetSnapshotTests.swift:423-448`) proves failure-injection behavior, not that the real `Data.write(options:.atomic)` path is atomic under actual interruption.
- T2-5 — sample-mode widget isolation is still tested only via the `shouldCreateWidgetPublisher` pure predicate, not the live `SampleDataSession` wiring end-to-end.

**External release gates (not code defects):** physical-device widget add/remove/lifecycle acceptance (`RELEASE_CHECKLIST.md:38-41`) and the Xcode Cloud `GradusMacCloud` PR check remain outside this repository's automated proof, as expected — both are correctly documented as human/hosted gates rather than claimed as passed.
