# Gradus release checklist

This is the release gate for changes that cross the GradusMac publisher,
GradusKit contract, and GradusiOS consumer.

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
