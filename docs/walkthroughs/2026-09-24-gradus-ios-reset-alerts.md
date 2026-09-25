# Gradus iPhone reset alerts: local visual walkthrough

Captured 2026-09-24 from the v14 working tree on a disposable iPhone 15 simulator running iOS 27.0. These four fixture routes supplement the six light/dark Settings snapshot pairs recorded on the pinned iPhone 16 / iOS 26.5 test destination. The walkthrough uses local, deterministic states; it does not access accounts or CloudKit, install a signed candidate, or prove notification delivery.

| State | Capture | Observed result |
| --- | --- | --- |
| Off | [PNG](2026-09-24-gradus-ios-reset-alerts/reset-alerts-off.png) | Both reset-alert switches are off and the first observed count is described as a baseline. |
| On | [PNG](2026-09-24-gradus-ios-reset-alerts/reset-alerts-on.png) | Separate New banked resets and Usage refilled switches are on. Codex banked state is Unavailable and the Claude limitation is explicit. |
| Requesting | [PNG](2026-09-24-gradus-ios-reset-alerts/reset-alerts-requesting.png) | Both reset switches remain on but unavailable during the simulated permission request; the complete waiting message is visible. |
| Denied | [PNG](2026-09-24-gradus-ios-reset-alerts/reset-alerts-denied.png) | The denial explanation and complete Open iOS Settings recovery control are visible. |

The capture route checks the exact fixture marker and keeps the full informational or recovery element within the screenshot viewport. All four routes completed; each generated one nonempty PNG. The requesting route initially exposed an ambiguous accessibility identifier on a SwiftUI label and a viewport crop. The final capture selects its text element and requires the complete state plus bottom margin. Earlier failed diagnostics are retained outside the checkout under `/private/tmp/gradus-v14-failed-captures/`.

The macOS and iOS system-owned permission sheets, signed Keychain access, CloudKit delivery, and physical notification reception still require candidate-bound device acceptance before release.
