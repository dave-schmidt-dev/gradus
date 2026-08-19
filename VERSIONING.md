# Gradus app versioning

This is the normative versioning policy for Gradus. It separates the product
version a user sees from the build identifier Apple requires for every upload.

## The two Apple identifiers

| Setting | Meaning | Example | Rule |
| --- | --- | --- | --- |
| `MARKETING_VERSION` / `CFBundleShortVersionString` | Product release version | `1.4.1` | Semantic version; changes only when the product release changes |
| `CURRENT_PROJECT_VERSION` / `CFBundleVersion` | Apple build identifier | `10` | Monotonically increasing integer; every uploaded archive needs a new value |

TestFlight should be read as `1.4.1 (10)`: product version `1.4.1`, build
`10`. The build number is not the patch component and must never be rendered
as `1.4.10`.

The existing `1.4` TestFlight train, including builds 8–10, is legacy history.
Do not rewrite App Store Connect's recorded versions. The next product-version
bump should use three components, such as `1.4.1`.

## Semantic version rules

- **Patch** (`1.4.1`): bug fixes, small UI corrections, accessibility fixes,
  and behavior-preserving polish.
- **Minor** (`1.5.0`): a new user-facing feature, workflow, screen, or
  coordinated Mac/iOS feature group that remains compatible with existing
  data and users.
- **Major** (`2.0.0`): a breaking snapshot/CloudKit contract, migration,
  incompatible user workflow, or other change requiring an upgrade boundary.

Snapshot and CloudKit schema versions remain separate technical contract
versions. A schema change does not automatically determine the marketing
version; classify the user-visible impact using the rules above and coordinate
the producer/consumer release under `RELEASE_CHECKLIST.md`.

## Release-train and log rules

1. Choose the semantic product version before the release gate starts.
2. Create one user-facing `CHANGELOG.md` entry per semantic product version.
3. Record individual Apple build attempts, superseded candidates, and the
   reason for any re-upload in local `HISTORY.md`, not as duplicate semantic
   releases in `CHANGELOG.md`.
4. A second build with the same marketing version is allowed only for a
   release-blocking correction or a failed/superseded candidate. It remains
   the same release train and is labeled by build number only.
5. Small non-blocking changes wait for the next patch release instead of
   creating another overnight TestFlight build. "Small non-blocking" means
   cosmetic/non-functional -- it does not mean iOS-visible changes go
   unshipped. A change that alters what the iOS app shows or does (a bug fix,
   a UI correction, a new feature) is not done until it has a semantic
   version bump (patch at minimum, per the rules above) and a new TestFlight
   build. This rule governs batching *trivial* tweaks into that release; it
   is not a default to skip releasing shipped code altogether. If the change
   is coupled (see "Coupled platform releases" below), bump both targets.
6. A release candidate is not prepared or uploaded until its code, documentation,
   review, and required producer/consumer verification are complete.
7. The candidate ledger binds one source/project/artifact/version/build tuple;
   upload acceptance, processing/compliance, and internal-group assignment are
   separate receipt predicates. A candidate is not an App Store submission.

The Apple upload script owns build-number allocation by querying App Store
Connect. Never hand-edit a previously used build number or treat the checked-in
build number as the source of truth for the next upload.

## Coupled platform releases

When an iOS feature consumes a Mac-published field, record, or behavior, the
Mac producer and iOS consumer share one semantic release train. Build and test
both, verify the Mac publish in the matching CloudKit environment, and upload
the iOS artifact only after that evidence exists. A local Mac republish does
not require notarization; a distributed Mac artifact does.

**GradusMac carries the same `MARKETING_VERSION` as GradusiOS.** Sharing a
release train means sharing its number: when a train ships coupled behavior,
bump both targets in `app/project.yml` to the same semantic version in the same
change. The two `CURRENT_PROJECT_VERSION` values stay independent — they are
per-target Apple build identifiers, and only the iOS one is allocated from App
Store Connect.

The Mac is not exempt because it is undistributed. It sat at `0.1.0` through
the `1.5.0` train while containing that train's pace-ramp behavior, which made
its version string useless for the one question it exists to answer: whether an
installed copy has the coupled change. A producer whose version cannot be
compared to the consumer's defeats the point of a coupled release train.

Because the Mac is installed by local republish rather than by Apple, a bump
only reaches the running app when the bundle is rebuilt and swapped into
`/Applications`. Bump and rebuild together, or the repo and the menu bar
disagree.
