# iOS Small Widget — Independent Verification

Scope: `7af1189..HEAD` on `feat/ios-small-widget`. Commits: `b73661d`, `4e2d56c`, `6d9935f`, `093a68e`.

Method: git diff inspection + direct file reads against current HEAD (working tree matches HEAD, clean). Parallel deep-dive agents per completed task, plus spot-checks run directly.

---

## Cross-cutting finding (found before per-task review)

**FINDING C1 — Wave 3 (nested signing / entitlement verification) is entirely absent from this diff, and the release pipeline still applies one signing profile to every target.**

- `git diff --stat 7af1189..HEAD` touches no release-signing files: `app/archive-upload-ios.sh`, `app/test-archive-upload-ios.sh`, `app/release_prepare_bridge.py`, and `app/test_gradus_release_bridge.py` are unchanged.
- `app/archive-upload-ios.sh:1208` still passes a single `PROVISIONING_PROFILE_SPECIFIER="$SIGNING_PROFILE_NAME"` override to `xcodebuild archive`, which the plan (`.plans/gradus/ios-small-widget-2026-08-23.md` Task 3.1) explicitly says must be removed so the main-app profile can never be applied to the new `.appex`. It was not removed.
- No new App ID/profile validation, no nested nested-nested nested extraction/entitlement verification, no `GradusWidget.entitlements` App Group cross-check against the archived binary exists anywhere in the diff.
- `RELEASE_CHECKLIST.md`, `VERSIONING.md`, and `TESTING.md` have zero mentions of "widget" — none of these were touched despite the plan's Wave 4 listing them as files to update.
- Consequence: an actual archive/upload attempt with today's script will almost certainly either (a) fail to sign the widget extension at all (wrong/no profile for the new bundle ID), or (b) silently succeed with an unsigned or wrongly-provisioned `.appex`, which is exactly the failure mode Wave 3 existed to prevent. **The stated goal "suitable for a TestFlight upload after all repository gates pass" is not met** — the repo can pass its local simulator/unit gates while remaining unable to produce a valid signed nested archive.

Severity: **HIGH**. This is a scope gap against both the approved plan and the original requirement, not a subtle bug — the whole Wave 3 workstream is missing.

**Update — confirmed mechanically by the Task 4 review agent, with two concrete failure modes:**

- **C1a — the next build-number bump will desync the widget from the app.** `app/archive-upload-ios.sh:987-992`'s sed range for rewriting `CURRENT_PROJECT_VERSION` is anchored `/^  GradusiOS:/,/^  [A-Za-z0-9_]+:/`, which terminates at the next top-level YAML key — `GradusWidget:` (`project.yml:231`) — so only GradusiOS's build number is rewritten. The archive step (`archive-upload-ios.sh:1201-1207`) passes no override, relying entirely on `xcodegen generate` from the (partially-updated) `project.yml`. Next release: GradusiOS ships `CFBundleVersion 13`, the embedded `GradusWidget.appex` still declares `12` (from `project.yml:246`, unbumped) — App Store Connect rejects with an extension/app build-number mismatch.
- **C1b — repackaging signs only the outer `.app`; the embedded `.appex` is left dev-signed with no distribution profile.** `archive-upload-ios.sh:1213-1248` copies the profile and codesigns `Payload/GradusiOS.app` only; nothing in the script touches `Payload/GradusiOS.app/PlugIns/GradusWidget.appex`. Nested code must be signed inside-out (extension first, then the containing app), and the extension's own bundle ID needs its own distribution profile — neither happens.
- **C1c — no version-parity gate exists.** `validate_common_marketing_version` (`archive-upload-ios.sh:85-93`) checks GradusMac↔GradusiOS only; `test-gate-selfcheck.sh`'s widget contract check (`:200-229`) validates selector/embed/source but never marketing/build version, so a future version bump that misses the widget target fails silently until upload.

These are not hypothetical — they are the literal current behavior of the unmodified script, traced line-by-line. Combined with the plan's explicit Task 3.1 requirement to remove the profile override and add nested-signing verification (neither done), this confirms Finding C1 at HIGH severity with no mitigating factor.

---

## Task 1 — Shared widget snapshot model and App Group storage contract (GradusKit)

Confirmed directly (not just via delegated agent): `app/GradusKit/Sources/GradusKit/WidgetSnapshot.swift` implements the allowlist correctly (`schemaVersion`, `phoneSyncDate`, `providerName`, `providerDisplayName`, `status`, `selectedWindow` only — no `data`, no free-text error, no identity/tokens/paths), rejects unsupported schema versions in `init(from:)` (:172-175) rather than crashing, and `selectWidgetWindow`/`compareWidgetWindows` (:100-118) implement the exact plan rule: highest signal severity → lowest `percentLeft` → ascending window ID, with invalid percentages filtered first and an empty result returning `nil` for the bounded no-window case. `app/GradusKit/Sources/GradusKit/WidgetSnapshotStore.swift` writes via `Data.write(options: .atomic)` (:26-27, :37) — genuine tmp-then-rename atomicity — and both `loadSnapshot()` (malformed JSON, unknown schema, missing file) and the constructor's directory creation swallow failures via `try?`, degrading to `nil`/no-op rather than throwing into a crash. No force-unwraps found in these two files.

`app/Shared/ProviderRanking.swift` additions (`fixedMostUrgentRankedProviders`/`fixedMostUrgentProvider`, :314-326) are purely additive — new functions that call the pre-existing `rankProviders`/`rankedPartition` unmodified; `sortPartition`, `compareMostUrgent`, and the active/exhausted split are untouched by this diff (confirmed by direct read, not just diff stat), so the INV-13 exception cannot leak into full-surface (Mac/iPhone/iPad) ranking. **PASS** on all items independently checked.

Not independently re-run: `swift test` for `GradusKitTests/WidgetSnapshotTests.swift` — the harness's non-interactive permission gate rejected direct `swift test` invocation (`This command requires approval`, no interactive approver available in this session). Test-file *content* was reviewed for the presence of the required cases; verdict on whether it actually passes is UNVERIFIED by execution, PASS by static reading (round-trip, unknown-schema, malformed/missing-file, atomic-replacement, allowlist, tie-break, and no-window cases are all present as distinct test functions).

A second, independently-dispatched agent re-derived the same eight items from GradusKit's side and corroborates the PASS verdicts above, but surfaced defects the first pass missed by following the contract downstream into `app/GradusWidget/`:

**FINDING T1-1 (HIGH, corroborates T3-1) — same percent-formatting divergence**, independently found from the GradusKit side: `app/GradusWidget/WidgetFormatting.swift:6` bypasses `GradusKit.PercentFormat.swift:37-43`. Two independent reviews reaching the same file:line raises confidence this is real, not a misread.

**FINDING T1-2 (HIGH, confidence: medium) — `WidgetProviderStatus` is written but never read by the extension, so an errored-but-cached provider can render as a normal, current reading.** `WidgetSnapshotPublisher.swift:96-108` sets `.status` from the provider's real health, but no file under `app/GradusWidget/` references `.status` at all — the view only branches on `selectedWindow` presence/nil. If a provider is `ok: false` while still retaining prior windows (the same last-known-good retention pattern the Python/TUI side documents for transient errors), the widget would show a green/normal percentage and "synced Nm ago" instead of surfacing the error the dashboard shows. This needs human confirmation of whether iOS `ProviderStatus` actually retains windows on `ok:false` the way the Python snapshot does — flagged at medium confidence for that reason — but if it does, this is a real parity gap with INV-13's read-only-consumer contract.

**FINDING T1-3 (MEDIUM) — errored-provider-first ranking is correct for a list but wrong for a single-slot widget.** `attentionTier` in `ProviderRanking.swift:240-243` ranks `!rankingIsOK` (tier 0) ahead of attention-needed (tier 1) and normal (tier 2) — appropriate when rendering a full list where errors should surface at the top, but `fixedMostUrgentProvider` takes only `.first`, so a provider with no data at all (tier 0, e.g. Codex erroring with zero windows) is selected over a provider at 3% remaining in the red zone (tier 1/2). The widget's single slot can therefore show "usage unavailable" while a genuinely critical provider is one tap away and unshown.

**FINDING T1-4 (LOW) — duplicated signal-severity ramp.** `WidgetSnapshot.swift:86-94` reimplements the same red>orange>yellow>green>unknown ranking already expressed in `ProviderRanking.swift:227-237` (`mostUrgentSignalRank`) — a future retune of one ramp can silently desync widget window selection from dashboard signal color, the same duplication class INV-13's shared-seam rationale exists to prevent.

**FINDING T1-5 (LOW) — fractional-second ISO8601 reset timestamps silently drop.** `WidgetSnapshot.swift:80-81` uses a bare `ISO8601DateFormatter()` without `.withFractionalSeconds`, while GradusKit's canonical reset parser (`FriendlyDate.swift:41-49`) tries the fractional-seconds variant first. A reset string with a fractional-seconds suffix would render on the dashboard but silently disappear from the widget's reset line.

**FINDING T1-6 (LOW) — atomic-write test doesn't test atomicity.** `WidgetSnapshotTests.swift:142-167` proves error propagation from an injected throwing writer, not that the real `Data.write(options:.atomic)` path actually preserves prior bytes on a failed/interrupted write — the atomicity claim in INV-14's rationale has no test exercising the production writer under failure.

**FINDING T1-7 (LOW) — raw window IDs can reach the widget UI unlabeled.** `WidgetSnapshot.swift:34` falls back to the raw id (`labels[id] ?? id`) for any id outside the fixed label table, and this fallback is pinned by a test (`WidgetSnapshotTests.swift:311`) rather than treated as a gap — in tension with INV-14's plan-derived language "requiring its normalized window label" for unusual/new window ids.

---

## Task 2 — iOS app publication of live state into the shared container

**FINDING T2-1 (HIGH) — clearing the widget on account/authority loss is not durable; a later publish trigger resurrects the old account's data.** `app/GradusiOS/DashboardViewModel+AccountStatus.swift:61,64` clears the widget snapshot but never clears the underlying local cache (`allProviders`/`lastSyncedAt` survive in memory/disk). Any subsequent publish trigger — the threshold `didSet` (`DashboardViewModel.swift:139`) or app `init` on next launch (`DashboardViewModel.swift:351`) — republishes from the retained cache before any account check re-runs. Concrete scenario: sign out of iCloud → widget correctly clears → relaunch the app → widget silently repopulates with the signed-out account's quota data. The inverse also fails: after `.noAccount` → `.available` recovery, nothing republishes until a *successful* fetch completes, so a legitimate recovery leaves the widget blank while the dashboard already shows cached data.

**FINDING T2-2 (MEDIUM) — disabling iCloud sync (the in-app "sign out" equivalent) never clears the widget.** `DashboardViewModel.swift:100-104` → `commitRequiredICloudMode` (:354-363) has no widget-clear call, so toggling sync off leaves the widget serving live quota data indefinitely. Same root cause as T2-1.

**FINDING T2-3 (MEDIUM) — the threshold slider performs synchronous main-thread App Group file I/O on every step, not just on commit.** `DashboardViewModel.swift:139`'s `didSet` re-publishes through `WidgetSnapshotPublisher.swift:76` on every value change; `SettingsView+WarningThreshold.swift:19` is a `Slider(step: 1)`, so a single drag gesture can fire up to ~100 synchronous file reads/writes plus WidgetKit reload requests on the main thread — a UI-hitch risk and a WidgetKit reload-budget burn the plan's "conservative reload" intent did not anticipate.

**FINDING T2-4 (MEDIUM) — a missing/misconfigured App Group entitlement degrades to a permanently-silent no-op with no diagnostic.** `WidgetSnapshotPublisher.swift:45-47` returns `nil` if the App Group container URL can't be resolved, and `GradusiOSAppConfiguration.swift:52` propagates that nil with no log; separately, if `FileWidgetSnapshotStore`'s directory-creation `try?` fails, every subsequent `saveSnapshot` throws into an empty catch (`WidgetSnapshotPublisher.swift:80-83`) for the process lifetime. Since `093a68e` just introduced this entitlement, a signing/profile misconfiguration (see Finding C1) would ship a build where the widget is permanently stuck on placeholder with zero warning signal anywhere in logs.

**FINDING T2-5 (LOW) — test-coverage gaps.** Sample-mode isolation is tested only as a pure predicate (`shouldCreateWidgetPublisher`, `WidgetSnapshotPublisherTests.swift:308-321`) and does not exercise the actual `SampleDataSession` wiring; `failedFetchAndCacheCommitDoNotReload` discards `sync()`'s return value so it can't actually assert non-interference; there is no test for republish-after-clear (T2-1) or for `.restricted` account state; the `RecordingWidgetStore` test double always returns the in-memory object from `loadSnapshot`, making the corrupt-file-on-disk path (T2-4-adjacent) structurally untestable with today's fixtures.

**Verified correct (no finding):** `syncedAt`/`phoneSyncDate` is sourced from `lastSyncedAt` set at commit time (`+Sync.swift:196`), never from `connectedSourcePublishedAt` — matches the plan exactly. WidgetCenter reload calls are gated on save/clear success, not fired unconditionally (`WidgetSnapshotPublisher.swift:79`, `:90`). The widget-store write is a synchronous, non-blocking, same-thread call inside the existing commit path — it cannot alter sync's own success/failure signaling (`synchronize` returns `Void` and swallows; `performSync` returns `true` regardless of widget-store outcome) — so it is "additive" in effect even though not literally fire-and-forget-async. UI-test/sample injection passes `nil` for the publisher (`GradusiOSApp.swift:71-74`; `SampleDataSession.swift` uses a separate convenience init). The projection itself carries only name/displayName/status/window — no `data`, no error text. No exploitable race: all publish/clear calls run on `@MainActor` with no `await` between load and write.

---

## Task 3 — Small WidgetKit extension (timeline provider, view, formatting, snapshots, tests)

Verdicts: family/StaticConfiguration restriction PASS · zero network/CloudKit/credential access PASS (extension links GradusKit, which itself contains CloudKit imports for the full-app code paths, but `APPLICATION_EXTENSION_API_ONLY: YES` is set and no call path from the extension reaches them — smell, not a violation) · timeline provider contract PASS · view-state coverage PASS · accessibility PASS with one defect below · `containerBackground(for: .widget)` PASS · tap-to-open PASS · entitlements PASS (App Group only) · percent formatting **FAIL** · test coverage FAIL (one gap).

**FINDING T3-1 (HIGH) — widget percent formatting bypasses `GradusKit.percentText` and independently truncates, so a live sub-1% window reads and is spoken as "0%".**
`app/GradusWidget/WidgetFormatting.swift:6` computes `"\(Int(max(0, min(100, percentLeft)).rounded(.down)))%"` instead of reusing `GradusKit.PercentFormat.swift:37-43`'s below-10%-keeps-one-decimal rule (the same rule README.md:145-150 states is "implemented twice... and pinned by a truth table both test suites read" — the widget is now a third, divergent implementation). A window at 0.7% (still live: `percentIsDepleted` is `<= 0.5`) shows `0%` on the widget vs `0.7%` on the dashboard, and the VoiceOver label at `WidgetFormatting.swift:54` routes through the same function, so it is spoken as "0 percent remaining" for a window that is not exhausted. Also collapses non-finite input to a plain value instead of `n/a`.

**FINDING T3-2 (HIGH) — sync age is frozen at timeline-entry generation, producing a false "synced <1m ago" for up to ~30 minutes, which is the exact 180-second-freshness promise the plan forbids.**
`app/GradusWidget/GradusSmallWidgetView.swift:105` computes `syncedAge(from: snapshot.phoneSyncDate, now: entry.date)` against the static `entry.date` captured when the timeline entry was built; `WidgetTimelineProvider.swift:75` only *requests* a reload `.after(entry.date + 30min)` (WidgetKit may honor this later under system budget). A sync at 12:00 viewed at 12:29 still reads "synced <1m ago." This directly contradicts plan text ("copy and tests must not promise the app's 180-second freshness") and makes the "aged-sync" view state — the only stale/current signal — effectively unreachable during the window it matters most.

**FINDING T3-3 (MEDIUM) — reset-time formatting hardcodes a 12-hour US pattern regardless of locale**, `WidgetFormatting.swift:36` (`"MMM d, h:mm a"`), even though a `locale` parameter is accepted — an `en_GB`/`de_DE` user gets `Aug 29, 9:40 AM` rather than a 24-hour, locale-ordered string. This is new logic (no existing reset-formatting helper was reused), not an inherited bug.

**FINDING T3-4 (MEDIUM) — placeholder view's accessibility label is likely overridden by its children.** `GradusSmallWidgetView.swift:56` sets `.accessibilityLabel("Gradus usage loading")` on a `VStack` without `.accessibilityElement(children: .ignore)` (unlike the `message(...)` and `current(...)` variants at :73–74 and :110–111), so VoiceOver in the widget gallery likely reads child text nodes instead, including a fabricated "synced <1m ago"-style string from redacted placeholder content.

**FINDING T3-5 (LOW) — no test asserts `placeholder(in:)` returns the placeholder state**, despite placeholder being first in the plan's enumerated required states; light/dark snapshot coverage is limited to the "current" state only (acceptable per plan wording, not a defect on its own).

**FINDING T3-6 (LOW) — force-unwrap of `snapshot.selectedWindow!`** at `GradusSmallWidgetView.swift:78`. The timeline provider guards this today, but `.current(_:)` is a public case constructible with a nil window elsewhere (e.g. in tests or future call sites), making this the one unsafe consumer of an otherwise-nil-safe model.

---

## Task 4 — Xcode target configuration, entitlements, gate coverage, walkthrough coverage, release documentation

Confirmed PASS: exactly one widget product/copy-phase/dependency reference in `project.pbxproj` (build file :97, copy phase :296, product ref :376/:1115, dependency :1167→:1781 — no duplicates or stray refs); `project.yml` target fields (bundle ID, entitlements, `APPLICATION_EXTENSION_API_ONLY`, deployment target, `GradusWidgetSupport` dependency) match the generated `project.pbxproj` at every spot-checked field; App Group string matches exactly between `GradusiOS.entitlements` and `GradusWidget.entitlements`; widget entitlements are minimal; the walkthrough (`app/release_candidate/walkthrough.py`) has concrete new route/control/screen/state markers for widget gallery, add, and states, wired into `_validate_source_markers` and covered by `test_walkthrough.py`; marketing version `1.9.0` is consistent across GradusMac/GradusiOS/GradusWidget in `project.yml` at HEAD, matching `CHANGELOG.md`.

**FINDING C1a/b/c** (nested-signing and build-number gaps) — see the Cross-cutting finding section above; this agent supplied the mechanical proof for Finding C1.

**FINDING T4-1 (MEDIUM) — no automated gate enforces widget/app version parity going forward.** `validate_common_marketing_version` (`archive-upload-ios.sh:85-93`) only compares GradusMac↔GradusiOS; `test-gate-selfcheck.sh`'s widget-contract check (:200-229) validates selector/embed/source presence but never checks marketing or build version against the other two targets. Today's values happen to agree; nothing stops the next bump from silently missing the widget target.

**FINDING T4-2 (LOW) — the widget-manifest self-check's "absent target source" mutation test is weaker than its name implies.** `test-gate-selfcheck.sh:560-566` renames a declared source file and expects the check to fail, but the check that actually trips is a literal-string assertion on the YAML text (:213), not the file-existence checks at :219-220 (which still probe the original hardcoded path) — so the test proves the string-match path works, not that a genuinely missing/renamed source file is caught by file-existence checking. A real accidental-rename-without-file-move could pass undetected.

**FINDING T4-3 (LOW) — the widget scheme's testable-list check is anchored at the wrong YAML scope.** `test-gate-selfcheck.sh:206`'s `sed` range starts at the `GradusWidget:` *target* key rather than the scheme's own key, so the `- GradusWidgetTests` assertion (:214) would pass even if it matched a downstream unrelated occurrence rather than the actual widget scheme's testable list.

**FINDING T4-4 (LOW) — INVARIANTS.md's "aggregate floor is therefore 21" is ambiguous, not wrong.** `INVARIANTS.md:171-175` reads as if 21 is the whole 16-leg manifest's floor; it's actually the iPad leg's own floor (12 snapshot selectors + 9 UI workflows). The 16 per-leg floors actually sum to 301 (confirmed against `test-gate.sh`'s per-leg minimums). Not a defect in the gate itself, just confusing invariant prose — worth a wording fix, not a blocker.

**FINDING T4-5 (LOW) — no widget-removal route in the walkthrough.** Add-to-Home-Screen and the gallery are covered; there is no corresponding "remove widget" route/state, which the plan's human-acceptance checklist item 2 ("Add/remove the small widget...") implies should exist.

**UNVERIFIED (explicitly, not claimed as PASS):** `xcodegen generate` idempotency — running it was denied by the harness's permission gate in this session; this specific plan acceptance criterion was not independently executed and should be spot-checked by a human or CI before relying on it. Same permission barrier prevented direct `swift test`/`xcodebuild test` execution for the leg-count and test-pass claims elsewhere in this report; those are PASS-by-static-reading only, not PASS-by-execution.

---

## Verdict

**FAIL** — one HIGH-severity cross-cutting release-pipeline gap plus multiple confirmed HIGH-severity in-app defects. The core widget contract (data model, allowlist, atomicity, App Group wiring, extension isolation, INV-13/14 boundary) is well-built and mostly matches the plan; the defects are concentrated in presentation-layer correctness and the release/signing path, not in the security-sensitive data-isolation core.

### Findings by severity

**HIGH**
- **C1** (+ C1a/b/c) — Wave 3 nested-signing work is entirely absent; `archive-upload-ios.sh` still applies one signing profile to the whole archive, never bumps the widget's own `CURRENT_PROJECT_VERSION`, and never signs/provisions the embedded `.appex`. A real archive/upload attempt will fail or ship a broken nested bundle. `RELEASE_CHECKLIST.md`/`VERSIONING.md`/`TESTING.md` were never updated as the plan required.
- **T2-1** — clearing the widget on account/iCloud-authority loss is not durable; a subsequent app launch or threshold change republishes stale/wrong-account data from the still-live local cache before any account re-check runs.
- **T3-1 / T1-1** (same defect, found independently twice) — the widget's own percent formatter bypasses `GradusKit.percentText`, so a live sub-1% window (e.g. 0.6–0.9% remaining) renders and is spoken by VoiceOver as "0%," contradicting the dashboard and the documented truncate-with-decimal rule.
- **T3-2** — sync age is computed against a frozen timeline-entry timestamp, not wall-clock time, so "synced <1m ago" can read wrong for up to ~30 minutes — the exact freshness overpromise the plan explicitly forbids.
- **T1-2** (medium confidence, needs human confirmation) — `WidgetProviderStatus` is written into the snapshot but never consulted by the extension's view logic; if iOS `ProviderStatus` retains prior windows on `ok:false` the way the Python/TUI side does for transient errors, an errored provider could render as a normal "current" reading on the widget.

**MEDIUM**
- T2-2 (disabling sync never clears the widget), T2-3 (slider drag causes ~100 synchronous file I/O + reload calls), T2-4 (misconfigured App Group entitlement fails silently with no diagnostic), T1-3 (error-provider-first ranking is wrong for a single-slot widget and can hide a genuinely urgent provider behind a data-less errored one), T3-3 (hardcoded 12-hour US date format ignores the accepted locale parameter), T3-4 (placeholder accessibility label likely overridden by un-suppressed children), T4-1 (no automated widget/app version-parity gate).

**LOW**
- T2-5, T1-4, T1-5, T1-6, T1-7, T3-5, T3-6, T4-2, T4-3, T4-4, T4-5 — test-coverage gaps, one duplicated signal-severity table, a bare (non-fractional-seconds) ISO8601 parser, an untested atomic-write failure path, a force-unwrap on a currently-unreachable nil, and minor gate/documentation wording issues. Full detail in the per-task sections above.

### Explicitly unverified (not claimed PASS, not claimed FAIL)
- `swift test` / `xcodebuild test` execution for GradusKit, GradusiOS, and GradusWidget test targets — blocked by the harness's non-interactive permission gate for `swift`/`xcodebuild` invocations. All test-content verdicts above are by static reading of the test files, not by observed pass/fail output.
- `xcodegen generate` idempotency against the committed `project.pbxproj` — not executed, for the same reason.

### Recommendation
Do not treat this branch as TestFlight-ready. Before any archive/upload attempt: (1) close Finding C1/C1a/b/c — extend the build-number rewrite and nested codesign/provisioning to `GradusWidget`, and add the version-parity and nested-signature checks the plan's Wave 3 specified; (2) fix T2-1 (durable widget clear on account loss) since it's a real data-exposure-adjacent correctness bug, not just a UI nit; (3) fix T3-1/T1-1 (route widget percent formatting through `GradusKit.percentText`) and T3-2 (compute sync age from wall-clock time, not the frozen entry timestamp) since both are plan-violating, user-visible-every-time defects; (4) get a human or CI to actually execute `swift test`/`xcodebuild test`/`xcodegen generate` once outside this session's permission constraints, since none of those were observed to pass in this review.

