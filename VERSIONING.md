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
   creating another overnight TestFlight build.
6. A release candidate is not uploaded until its code, documentation, review,
   and required producer/consumer verification are complete.

The Apple upload script owns build-number allocation by querying App Store
Connect. Never hand-edit a previously used build number or treat the checked-in
build number as the source of truth for the next upload.

## Coupled platform releases

When an iOS feature consumes a Mac-published field, record, or behavior, the
Mac producer and iOS consumer share one semantic release train. Build and test
both, verify the Mac publish in the matching CloudKit environment, and upload
the iOS artifact only after that evidence exists. A local Mac republish does
not require notarization; a distributed Mac artifact does.
