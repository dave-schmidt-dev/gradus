# Gradus release checklist

This is the release gate for changes that cross the GradusMac publisher,
GradusKit contract, and GradusiOS consumer.

The companion policies are [`VERSIONING.md`](VERSIONING.md) and
[`TESTING.md`](TESTING.md). The generalized Apple-development standard lives
in the shared `apple_developer` project under `RELEASE_STANDARDS.md`.

## App Store publication roadmap (planned; not submission-authorized)

The current release path ends at internal TestFlight. Public App Store
submission is a later, human-authorized trigger. Gradus is free end-to-end: the
Mac publisher is not a paid prerequisite, and this version has no subscription
or In-App Purchase.

Before that trigger, the release owner must verify:

1. A normal Release `Explore Sample` path works on a clean iPhone/iPad install
   without GradusMac or pre-existing CloudKit data. It is labelled as sample
   data, exercises the normal dashboard, writes nothing to CloudKit, waits for
   live lifecycle work to quiesce before entry, suppresses remote pushes and
   notification registration while active, and has reset/exit paths from both
   the sample dashboard and its Settings variant.
2. The Antigravity card no longer reports a transient error during a healthy
   refresh cycle; a regression test and live health-window evidence exist.
3. The data-flow/security audit records each outbound data path, CloudKit
   permission, diagnostic/provider destination, retention/deletion behavior,
   credential boundary, and encryption classification.
4. Dead code, UI/gate coverage, public docs, release walkthrough, and provider
   branding/claims are clean.
5. App Store Connect metadata and evidence are complete: screenshots, age
   rating, privacy policy and App Privacy answers, support/marketing URLs,
   export compliance, copyright, review contact/notes, and the selected signed
   build. See Apple's [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/),
   [App Privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy),
   and [export-compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance).
6. Physical-device acceptance: verify adding and removing the small widget
   (`systemSmall`) on a physical iOS device, confirming gallery presentation,
   placeholder, current usage projection, tap-to-open dashboard navigation,
   and clean widget removal.

No item in this section submits an app; the final submission remains a separate
release-owner decision after the evidence is reviewed.

## Internal TestFlight candidate gate (INV-9)

This is an internal-TestFlight candidate path only. App Store submission,
public release, external testers, and group creation/deletion are excluded.
Preparation, upload acceptance, processing/compliance, and assignment are
separate gates. Keep the candidate record and receipt bound to the exact source,
artifact, version, build, producer evidence, and walkthrough digests.

### Nested signing, App Store profiles, and artifact proof

The iOS archive embeds the small widget extension (`GradusWidget.appex`). Release
signing, packaging, and verification enforce:

1. **Separate App IDs and profiles:** `GradusiOS` (`com.zerodelta.gradus.ios`) and
   `GradusWidget` (`com.zerodelta.gradus.ios.widget`) each require their own separate
   App Store provisioning profile ("Gradus iOS App Store (API-created)" and
   "Gradus Widget App Store (API-created)").
2. **Inside-out nested signing:** The embedded `.appex`
   (`Payload/GradusiOS.app/PlugIns/GradusWidget.appex`) must be signed first with
   the widget profile and widget entitlements, before the containing
   `Payload/GradusiOS.app` is signed with the iOS app profile.
3. **Nested artifact proof:** The candidate packager and verification gates inspect
   the unpackaged IPA to verify:
   - Nested `.appex` presence and inside-out code signatures.
   - Exact capability boundaries: the widget requests only
     `com.apple.security.application-groups` (`group.com.zerodelta.gradus`),
     plus system signing identity fields; verification rejects CloudKit and APS
     entitlements, and the extension contains no network or Keychain access.
   - Strict version and build parity: `CFBundleShortVersionString` and
     `CFBundleVersion` in the embedded widget match the containing app exactly.
4. **Small-only scope:** The widget is restricted to `systemSmall`; no medium/large
   families, configuration intents, or background network modes are permitted.

An assigned candidate is immutable. To prepare a replacement for a
release-blocking correction, run the upload wrapper from `app/` with
`--rollover-assigned --supersession-reason "<reason>"`. The wrapper archives the
old candidate workspace, evidence, and receipt under
`.release-state/archived/<candidate-id>/` before creating the replacement.
Superseding a frozen candidate is Amber per `~/.agent/prompts/_shared/gar.md`:
do it, record the supersession reason, and continue. Immutability forbids
mutating an assigned candidate in place; it is not a reason to end the turn.
Upload, local-install, and
notarization provenance checks allow only the exact untracked verification
report `verifications/2026-08-09-internal-testflight-candidate-migration-verification.md`.
The receipt journal must be inside the candidate workspace; rollover emits
archive-start and archive-complete progress and preserves that journal in the
archived workspace.

### Candidate-current walkthrough and release-owner handoff

Before the release owner authorizes TestFlight, generate the dated walkthrough
from the exact candidate ledger and IPA. The upload wrapper generates this
automatically under `.release-state/candidates/<candidate-id>/`; use the paths
it prints. A manual regeneration has this shape:

```bash
cd app
python3 -m release_candidate.walkthrough \
  --ledger ../.release-state/candidate.json \
  --artifact <candidate-ipa> \
  --output <candidate-state-dir>/walkthrough.md
```

Review onboarding, every reachable screen and control, each role/permission
variant, disabled and recovery states, and every system-owned sheet against the
matching TestFlight artifact. The source-backed manifest must include the empty
state's Explore Sample entry, the sample dashboard banner/reset/exit controls,
and the sample Settings reset/exit variant. The generator records the
walkthrough digest in the candidate ledger and refuses stale, mismatched, or
incomplete coverage.
This is a human release-owner gate for internal TestFlight only; it is not App
Store submission or proof of Apple processing/installability.

## Cross-platform compatibility gate (INV-9)

When a feature crosses the Mac publisher and iOS consumer, use INV-9's automated
producer-evidence gate; this checklist records release evidence but does not
duplicate that invariant's contract.

Before candidate upload:

1. Identify the producer, consumer, and shared contract in the release notes.
2. Run the candidate-bound local gate, which binds the readiness manifest to the
   current and checked-tree source digests and streams `app/test-gate.sh`. Retain
   its passing local-gate proof as the exact-source candidate evidence; the
   `GradusMacUI` leg launches the exact locally built GradusMac app product.
3. Run the scripted CloudKit schema-parity check — no manual CloudKit Console
   comparison required:

   ```bash
   ~/Documents/Projects/apple_developer/integrations/cloudkit-producer-check \
     --container iCloud.com.zerodelta.gradus --team 4CJ49V6QHW \
     --app-ledger .release-state/cloudkit-ledger.log
   ```

   This fails closed if the Production schema is missing anything the
   Development schema carries — the same class of drift wwpis's identical
   check caught for the `cloudkit.share` record type on 2026-08-14 (see
   `apple_developer/integrations/cloudkit_ckdb.py` in the shared
   `apple_developer` project). It needs `CLOUDKIT_MANAGEMENT_TOKEN`; no BWS
   consumer is wired for gradus's container yet. Registering one is Red per
   `~/.agent/prompts/_shared/gar.md` (new broker consumer), so notify once with
   that exact request and keep going: run the check if the release owner has
   already supplied a token, otherwise waive it with a recorded reason in the
   release notes and proceed through the remaining gates rather than ending the
   turn on it. This checks schema shape only; it does not confirm a publish
   actually reached CloudKit (see step 4) and does not push or promote — use
   `apple_developer/integrations/cloudkit-dev-push` /
   `cloudkit-prod-promote` for that, never the CloudKit Console.
4. Build GradusMac with the entitlements for the CloudKit environment being
   exercised, launch that binary locally, and confirm it publishes the new
   contract/data. A local republish does not require notarization. The actual
   gate is step 5 below — `archive-upload-ios.sh` refusing absent or stale
   producer evidence; treat the rest of this step as a troubleshooting aid for
   a failed publish, not a second manual sign-off.

   Read both logs when a publish looks wrong. `cloudd` reports what CloudKit did; GradusMac's own log
   reports what the app intended, and is the only place a *failed* save
   appears at all:

   ```
   /usr/bin/log show --predicate 'process == "cloudd"' --last 30m \
     --info --debug --style compact | grep -i gradus

   /usr/bin/log show --predicate 'subsystem == "com.zerodelta.gradus"' \
     --last 30m --info --debug --style compact
   ```

   From `cloudd`, expect `environment=Production`, `zoneName=GradusZone`, and
   one `was successfully saved to the server` line per provider record. From
   the app, expect a `publishing N of M provider(s)` line followed by
   `published N record(s) successfully` — and if anything failed, a
   `save failed for <provider>: <code name> (CKError <number>)` line per
   record (e.g. `save failed for Codex: zoneNotFound (CKError 26)`) plus a
   `publish incomplete` summary. A failure before any record result exists
   instead logs `cloud sync failed (operation <number>, error <code name>
   (CKError <number>))`. A publish that fails now says so; before
   2026-08-06 the app returned a bare failure count and `cloudd` showed only
   the records that worked.

   The line carries the code and nothing else on purpose — a `CKError`'s
   `userInfo` can hold the offending record and its fields, and that includes
   the usage data being published. If a code is not one the app has a name
   for, the line reads `unmappedCKErrorCode (CKError <number>)`; look the
   number up rather than assuming the publish path is broken.

   Three details are not optional: `/usr/bin/log` (in zsh, bare `log` is a
   shell builtin that fails with `too many arguments`), `--info --debug`
   (CloudKit logs at `info`; the default level filters it out), and **not**
   redirecting stderr to `/dev/null` — that combination silently produced "the
   app emits nothing" twice, and the wrong conclusion reached the docs both
   times.

   Warnings and errors are additionally mirrored to
   `~/Library/Logs/Gradus/GradusMac.log`, which outlives the unified log's
   retention. Read it when the release is being reviewed later than the
   `--last` window reaches. It contains release evidence only: the Mac test
   bundle is hosted inside a real GradusMac process, so the suite would
   otherwise append its own staged failures here, and it is redirected to a
   temporary directory instead (`GRADUS_MAC_LOG_DIR` overrides the location).
5. Confirm `archive-upload-ios.sh` accepts the current machine-written producer
   evidence for INV-9 before preparing/uploading the iOS artifact.
6. If the Mac artifact itself is being distributed, run the notarization gate
   too; local publisher verification alone is not a distribution artifact.
7. Record the matching Mac build, iOS build, schema state, and candidate
   preparation/upload results in local `HISTORY.md`; keep the user-facing
   `CHANGELOG.md` limited to concise tester-facing notes.

After upload, poll for the exact candidate build to process, surfacing progress
as it goes rather than blocking silently. Missing Compliance and internal-group
assignment are Red per `~/.agent/prompts/_shared/gar.md`: the first is a legal
declaration and the second needs the release owner's confirmed group identity,
so neither may be answered on their behalf. Notify once with the exact action
each requires, then continue every other parallelizable step instead of ending
the turn. Assign only the attended, pre-confirmed internal group. Persist the
redacted processing/compliance/assignment receipt. This does not submit to the
App Store.

The attended assignment trigger has this shape; replace every placeholder only
after the release owner has reviewed the candidate tuple and group identity:

```bash
bws-secret-exec app-store-connect-testflight-setup -- <candidate-id> <build> \
  --group-id <confirmed-internal-group-id> --group-name "<confirmed-group-name>" \
  --ledger .release-state/candidate.json \
  --evidence <candidate-state-dir>/candidate-evidence.json \
  --receipt-journal <candidate-state-dir>/receipt.json
```

A feature may ship on only one platform when the release notes explicitly
record that it has no producer/consumer or shared-contract dependency.

That exception is between Mac and iOS. It never applies between iPhone and
iPad: they are one artifact with one version, so there is no such thing as an
iPad-only or iPhone-only release (INV-12). A UI change lands on both size
classes in the same release, and the gate must exercise both destinations —
size-class-gated coverage that runs on only one is how a divergence stays
invisible. If a change genuinely cannot be expressed at one size class, say so
in the release notes as a limitation, not as a scope decision.

## Versioning gate

Use `MAJOR.MINOR.PATCH` for the product version. Treat Apple's build number as
an independent monotonically increasing upload identifier. One semantic version
gets one user-facing changelog entry; superseded TestFlight candidates belong
in local `HISTORY.md`. Do not create a new TestFlight build for a small,
non-blocking tweak after a candidate has already uploaded; batch it into the
next patch release. See [`VERSIONING.md`](VERSIONING.md) for the full policy.

## Feature and UI testing gate

Every new feature and every new user-facing UI element must ship with automated
regression coverage in the same change:

1. Pure logic gets a unit/property test.
2. New SwiftUI appearance gets light/dark snapshot coverage for its important
   states.
3. New interactive behavior gets an XCUITest/XCUIAutomation workflow test
   using stable accessibility identifiers or labels.
4. Producer/consumer changes get tests on both sides plus a shared fixture or
   integration assertion.
5. New tests must be wired into the test target and pass through
   `app/test-gate.sh`; manual-only validation requires a documented exception.

The full testing matrix and exception rule are in [`TESTING.md`](TESTING.md).

## Live signed-Keychain validation gate (human-executed)

Identity-bound Keychain ACLs cannot be exercised by an unsigned test binary, so
`app/test-gate.sh` stubs the `security` command and never touches a live Keychain
item. Before shipping a candidate that changes Claude, Cursor, or OpenCode Go
credential reads, the release owner runs this gate by hand against the signed,
installed candidate:

1. Install the signed candidate and confirm its Developer ID identity with
   `codesign -dv --verbose=4` before granting anything.
2. Run one refresh and confirm each Keychain-backed provider returns real windows
   without a Keychain prompt loop, using the fixed items `Claude Code-credentials`,
   `cursor-access-token`, and `OpenCode Go`.
3. Confirm the reads stay read-only: no `add-generic-password` or
   `delete-generic-password`, no token refresh, and no write-back to the item.
4. Confirm a revoked or expired session fails closed with the actionable
   re-authentication message rather than a fabricated zero.
5. Record the result in `HISTORY.md`. A failure here blocks the release even when
   the automated gate is green.

This gate is deliberately separate from the automated suite; it is evidence a
signed binary produced, not something a unit test can assert.
