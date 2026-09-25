# Gradus v14 Phase 4 verification

Candidate: local checkpoint from approved v14 reset-alert plan. No commit, push, install, upload, or release is part of this checkpoint.

## Evidence

- Mac Settings: six new reset-alert snapshots and seven existing baselines; 13 selectors passed. Dated walkthrough: `docs/walkthroughs/2026-09-23-gradus-mac-reset-alerts.md`.
- iOS Settings: six new reset-alert snapshots and six existing baselines; 12 selectors passed. Four iPhone walkthrough states captured: `docs/walkthroughs/2026-09-24-gradus-ios-reset-alerts.md`.
- Focused iPhone UI correction passed 2/2 (`/private/tmp/gradus-v14-ios-ax-4-iphone-ui.log`) and the original iPad requesting case passed 1/1 (`/private/tmp/gradus-v14-ios-ax-4-ipad-ui.log`). The canonical `GRADUS_STATIC_BASE=efdfbf630efd6dee10710a07d337662055c4edab bash app/test-gate.sh` gate then exited 0; `test-gate.sh` reported all destinations green. Counts: SwiftPM 130, pytest 1240, Mac 240, Mac UI 4, bridge 17, agent 23, iPhone 232, density phone/iPad 3/9, widget 21, iPad UI 16, and iPhone UI 16. The iPhone UI aggregate includes one intentionally skipped walkthrough test because capture environment variables were not configured; the four reset-alert routes were captured separately as documented above. Log: `/private/tmp/gradus-v14-phase4-full-gate-final-candidate.log`; SHA-256: `06ac396cd72673664eeb45fc61877f33ae6ee6b49fe12f29fd75e5f07a18ef4b`.

## External review

The completed Standard review read the full gate and iOS UI test source as embedded, line-numbered candidate bytes; the targeted remediation review read the corrected iOS UI test. Vibe timed out without a result; two earlier OpenCode calls returned empty after read-only tool permission denials. Those attempts were not treated as approval. Source-bound reports: `/private/tmp/gradus-v14-review/opencode-inline-result.txt` and `/private/tmp/gradus-v14-review/opencode-remediation-result.txt`.

Finding disposition:

- ACCEPT: Requesting UI test could read disabled from an unresolved switch query. It now asserts each role-specific switch exists before `isEnabled`.
- ACCEPT: App-scoped alert lookup could miss a SpringBoard permission prompt. The test now uses the existing app-first, SpringBoard-fallback helper.
- ACCEPT: Existing widget sizing test assumed its controls remained in the initial iPhone viewport. It now scrolls to the section and Automatic switch; focused iPhone run passed.
- ACKNOWLEDGE: The runtime counting-leg total does not itself prove each identity ran once. The static runner and self-check inspect declared invocations and UI targets; the present manifest and exact full gate are checked. Stronger runtime identity accounting is a future hardening option.
- ACKNOWLEDGE: The density selector validation checks sizes and source assertions, but not an explicit disjoint union. Current phone/pad selectors and counted legs are checked; no current omission was found.
- ACKNOWLEDGE: The deadline watchdog may conservatively report timeout for a process at the boundary. This fails closed; no false-green path was found.
- ACKNOWLEDGE: Additional cross-state absence and direct toggle-interaction UI assertions could strengthen future regression detection. Current state snapshots, fixture UI checks, and independent ViewModel opt-in tests cover the approved local checkpoint.
- ACKNOWLEDGE: Denied recovery is asserted visible rather than opening iOS Settings; the latter is deferred to candidate/device acceptance.
- REJECT: The iPad aggregate reporter is not an unexplained pure-XCTest leg; it emits Swift Testing and XCTest counts, as observed in the gate.
- REJECT: Non-exact floors for growing suites are intentional and documented, while fixed UI and iPhone scenario counts are pinned.
- REJECT: Reporter naming differences and `COUNTING_LEG_SOURCES` were style or incomplete-context findings; the self-check uses the sources array.
- REJECT: Further bidirectional scroll and asynchronous disabled-state waits are speculative for the synchronous fixtures and current section order; the focused iPhone/iPad runs passed.

The remediation reviewer confirmed all three accepted corrections are present and correctly ordered, with no confirmed regression. Its remaining timing/layout hypotheticals do not change the current tested state.

## Boundaries

This is local simulator/snapshot evidence. Signed Keychain ACL, live APNs/CloudKit delivery, installed runtime, physical devices, and owner release acceptance remain separate candidate-bound work.
