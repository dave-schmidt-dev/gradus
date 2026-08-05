# Gradus release checklist

This is the release gate for changes that cross the GradusMac publisher,
GradusKit contract, and GradusiOS consumer.

The companion policies are [`VERSIONING.md`](VERSIONING.md) and
[`TESTING.md`](TESTING.md). The generalized Apple-development standard lives
in the shared `apple_developer` project under `RELEASE_STANDARDS.md`.

## Cross-platform compatibility gate

When a feature requires another feature or platform, ship the dependency and
the dependent feature together. Do not upload the consumer while leaving the
producer on an older binary or schema contract.

Before the TestFlight upload:

1. Identify the producer, consumer, and shared contract in the release notes.
2. Build and test both GradusMac and GradusiOS with `app/test-gate.sh`.
3. Build GradusMac with the entitlements for the CloudKit environment being
   exercised, launch that binary locally, and confirm it publishes the new
   contract/data. A local republish does not require notarization.
4. Upload the iOS artifact only after the Mac publish evidence is present.
5. If the Mac artifact itself is being distributed, run the notarization gate
   too; local publisher verification alone is not a distribution artifact.
6. Record the matching Mac build, iOS build, schema state, and test/upload
   results in local `HISTORY.md`; keep the user-facing `CHANGELOG.md` limited
   to concise tester-facing notes.

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
