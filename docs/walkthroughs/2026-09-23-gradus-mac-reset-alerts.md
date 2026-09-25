# Gradus Mac reset alerts: local visual walkthrough

Captured 2026-09-24 from the v14 working tree on macOS 26.6.2 with a deterministic 460 × 1600 window-backed Settings fixture. This is local checkpoint evidence, not a signed or installed app walkthrough. The fixture uses fake notification, background-agent, and banked-access services; it does not access accounts, Keychain items, CloudKit, or system notification settings.

| State | Light | Dark | Observed controls |
| --- | --- | --- | --- |
| Enabled and authorized | [PNG](../../app/GradusMacTests/__Snapshots__/MacSettingsSnapshotTests/macSettingsResetAlertsOnLight.1.png) | [PNG](../../app/GradusMacTests/__Snapshots__/MacSettingsSnapshotTests/macSettingsResetAlertsOnDark.1.png) | Separate New banked resets and Usage refilled toggles, current Codex count Unavailable, explicit Claude limitation, and system authorization allowed. |
| Requesting permission | [PNG](../../app/GradusMacTests/__Snapshots__/MacSettingsSnapshotTests/macSettingsResetAlertsRequestingLight.1.png) | [PNG](../../app/GradusMacTests/__Snapshots__/MacSettingsSnapshotTests/macSettingsResetAlertsRequestingDark.1.png) | Both toggles remain visible with Requesting notification permission. |
| Denied and recovery | [PNG](../../app/GradusMacTests/__Snapshots__/MacSettingsSnapshotTests/macSettingsResetAlertsDeniedLight.1.png) | [PNG](../../app/GradusMacTests/__Snapshots__/MacSettingsSnapshotTests/macSettingsResetAlertsDeniedDark.1.png) | Denial text and the complete Open Notification Settings… button are visible. |

All six images include the Reset Alerts controls and the final About/Version row. The six-image recorder preserved the seven earlier Mac snapshot PNGs byte-for-byte; the 13-selector comparison passed on the same host and pinned timezone.

The macOS-owned first permission sheet and the handoff to System Settings were not exercised by these fixtures. A later signed-candidate walkthrough must capture those system surfaces and confirm notification delivery on the installed app before release acceptance.
