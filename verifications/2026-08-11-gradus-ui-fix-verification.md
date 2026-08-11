# Gradus iOS UI-fix verification — 2026-08-11

Classification: **GO**.

- `ListRow.toggle` now gives every toggle its readable label and an identifier; its three Settings callers supply unique explicit identifiers (`ListRow.swift:32-48,75-80`; `SettingsView.swift:132-136,170-179`). Static inspection found each production identifier once.
- The iPad-sensitive Show exhausted test now targets `show-exhausted-toggle`, rather than switch index 2 (`DashboardXCUITests.swift:161-171`). This is independent of the multi-column iPad Automatic switch declared in `SettingsView.swift:94-99`.
- Warning threshold has a direct slider identifier, at most three upward swipes until hittable, and a predicate expectation before the slider adjustment (`SettingsView.swift:239-240`; `DashboardXCUITests.swift:189-203`).
- The changes are accessibility-only modifiers and test code, with no layout/style modifier or snapshot baseline change. `swiftc -parse` passed for all three changed Swift files; `git diff --check` passed.
- Fresh result bundles passed the three GradusiOS UI tests on iPhone 16 and iPad Pro 11-inch (M5), including `testSettingsControlsUpdateLocalDisplayAndSyncPreferences()`.

Uncertainty / follow-up: neither fresh bundle is a VoiceOver traversal test, so duplicate spoken static-label/control focus is not directly demonstrated. The iPad bundle also records an unrelated `UIRequiresFullScreen` runtime warning. Neither blocks this fix.
