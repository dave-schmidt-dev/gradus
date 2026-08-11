# App Store privacy and data-flow evidence

**Audit date:** 2026-08-11
**Scope:** Gradus terminal monitor, GradusMac publisher, and GradusiOS consumer.

This is source evidence for the App Store packet. It is not a privacy policy,
legal advice, or an App Store Connect submission. The audit found no public
privacy-policy or support URL in the repository; none is invented here. No App
Store Connect action was taken.

## Data-flow inventory

| Path | Data sent/read | Purpose and boundary |
| --- | --- | --- |
| Terminal -> provider APIs | Provider quota/usage responses; local OAuth credentials or cached cookies are used for authentication | Read-only quota observation. `gradus/snapshot.py` projects only the `SAFE_DATA_KEYS` usage/reset allowlist. Credentials and raw responses are not projected. |
| Terminal -> local state | Credential-free `.state/snapshot*.json`; credential-free, date-partitioned history | The latest snapshot feeds GradusMac. History stores safe usage observations and fixed provenance only. |
| GradusMac -> CloudKit | One `ProviderStatus` record per provider in private container `iCloud.com.zerodelta.gradus`, zone `GradusZone` | Explicit “Enable iCloud Sync” opt-in. `app/GradusKit/Sources/GradusKit/CloudKitMapping.swift` is the authoritative field map. |
| CloudKit -> GradusiOS | Private-database record reads and zone-change notifications | Populate the dashboard and its offline last-synced cache. iOS does not write `CKRecord` values. |
| CloudKit subscriptions | Zone-sync subscription and optional warning query subscription | Wake iOS to refresh; the warning subscription is removed when notifications are disabled. |

### CloudKit record contents

`ProviderStatus` records contain: provider name/display name; success/error
state; usage windows (percent remaining, reset, window duration, and pace);
safe provider usage fields; observation/snapshot/publish timestamps; warning
and depleted flags; and optional display-only `sourceComputerName` and
`sourceUserName`. The record ID is the provider name. The source mapping does
not include account email, serial number, filesystem path, API token, cookie,
raw provider response, or device identifier.

The Mac publisher uses `recordsToDelete: nil` and only upserts changed records.
The iOS consumer handles server-reported changes/deletions but has no product
flow that requests record deletion.

## Local retention and deletion

- Provider credential caches under `.cache/` are local, mode `0600` in a mode
  `0700` directory. They are replaced by the credential bridge, removed when a
  provider rejects a session, or can be removed manually. There is no automatic
  time-to-live for a still-valid credential cache.
- The latest snapshots are replaced atomically. Credential-free Python history
  is pruned to the most recent seven days (`HISTORY_RETENTION_DAYS = 7`).
- GradusiOS stores the last-synced provider payload and change token in its
  Application Support directory. The cache has a `clear()` operation and is
  cleared when the zone is deleted/not found; there is no user-facing “delete
  my CloudKit data” control.
- GradusMac stores sync settings and sync bookkeeping in `UserDefaults`.
  Disabling sync stops future publishes; it does not delete already-published
  records.
- CloudKit record retention is therefore currently “until overwritten or
  deleted by an explicitly designed/admin-controlled operation.” A destructive
  user deletion workflow, including its authorization and confirmation design,
  remains a pre-submission product/legal decision. This audit intentionally does
  not add destructive CloudKit deletion.

## Privacy-manifest disposition

`app/GradusiOS/PrivacyInfo.xcprivacy` is the correct app-bundle artifact for
required-reason API declarations and collected-data declarations. It currently
declares UserDefaults reason `CA92.1`, no tracking, and an empty collected-data
array. Apple’s manifest schema requires each collected data type to carry an
Apple-defined category, linked/tracking flags, and purpose. The CloudKit schema
proves that usage data and optional display names cross the private database,
but this source audit does not establish the final App Store category,
user-linkage, or purpose answers for every field. The manifest was therefore
not changed rather than guessing a nutrition-label category. The release owner
must resolve those answers against the final product/privacy policy before
submission.

## Dependency and encryption disposition

The Gradus monitor has no Python `cryptography` import and does not decrypt
Chrome cookies. The dependency was removed from `pyproject.toml` and `uv.lock`
after the source import audit and lock resolution. The App Store Connect helper
scripts intentionally request `cryptography` as an explicit, ephemeral
`uv run --with` dependency alongside PyJWT when minting an ASC ES256 token;
that tooling dependency is separate from the Gradus runtime and was not
silently removed.

References: [Apple privacy manifest schema](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests),
[Apple collected-data categories](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype),
and [App Store Connect app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy).

## Provider relationship and API-status language

Gradus is an independent, unaffiliated client. “OpenAI,” “ChatGPT,”
“Anthropic,” “Claude,” “Google,” “Antigravity,” “GitHub,” “Copilot,” “Cursor,”
“Mistral,” “Vibe,” and “OpenCode” are the names and/or trademarks of their
respective owners. Their mention identifies the service whose usage data the
user asked Gradus to observe; it does not imply sponsorship, endorsement,
partnership, or certification.

The integrations are user-authorized, read-only, best-effort integrations with
provider endpoints or account APIs. Endpoint contracts, authentication
requirements, quota semantics, and availability can change without notice;
Gradus does not claim that any endpoint is official, stable, or supported by
the provider. A displayed quota is an observation at probe time, not a promise
of entitlement, availability, or remaining service capacity. If a provider
changes or rejects an endpoint, Gradus reports the provider as unavailable and
does not bypass authentication or fabricate a value.

The current source endpoints are listed in `gradus/providers/`:
OpenAI/ChatGPT usage, Anthropic Claude usage, Google Cloud Code quota,
GitHub Copilot, Cursor Dashboard, Mistral Vibe billing, and OpenCode Go.
This list is an implementation inventory, not a claim that each endpoint is a
public API or that the provider endorses the integration.

## Release gates still owned by the release owner

Before App Store submission, the release owner must provide the final privacy
policy URL and support/marketing metadata, decide the App Store data-category
answers, define and authorize any user deletion workflow, and publish accurate
App Store Connect responses. This document records evidence and explicit gaps;
it does not close those human or legal gates.
