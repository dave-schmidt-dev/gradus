import Foundation
import GradusKit
@testable import GradusWidgetSupport
import Testing

private let formattingTimeZone = TimeZone(identifier: "America/New_York")!

private func formattingSnapshot(
    status: WidgetProviderStatus = .warning,
    percentLeft: Double = 17,
    selectedWindow: Bool = true
) -> WidgetSnapshot {
    WidgetSnapshot(
        phoneSyncDate: Date(timeIntervalSince1970: 1_787_483_180),
        providerName: "codex",
        providerDisplayName: "Codex",
        status: status,
        selectedWindow: selectedWindow ? WidgetWindowSnapshot(
            id: "weekly",
            label: "Weekly",
            percentLeft: percentLeft,
            signalLevel: .red,
            resetDate: Date(timeIntervalSince1970: 1_788_010_800)
        ) : nil
    )
}

@Test func percentageFormattingPreservesSubOnePercentAndMissingValues() {
    #expect(WidgetFormatting.percent(17.9) == "17%")
    #expect(WidgetFormatting.percent(0.7) == "0.7%")
    #expect(WidgetFormatting.percent(0.6) == "0.6%")
    #expect(WidgetFormatting.percent(0.0) == "0.0%")
    #expect(WidgetFormatting.percent(100.0) == "100%")
    #expect(WidgetFormatting.percent(nil) == "n/a")
    #expect(WidgetFormatting.percent(Double.nan) == "n/a")
    #expect(WidgetFormatting.percent(Double.infinity) == "n/a")
}

@Test func resetCopyHandlesPresentAndMissingDates() {
    let calendar = Calendar(identifier: .gregorian)
    let resetDate = Date(timeIntervalSince1970: 1_788_010_800)
    let usReset = WidgetFormatting.reset(
        resetDate,
        locale: Locale(identifier: "en_US"),
        timeZone: formattingTimeZone,
        calendar: calendar
    )
    #expect(usReset?.contains("Aug 29") == true)
    #expect(usReset?.contains("9:40") == true)
    #expect(usReset?.contains("AM") == true)

    let gbReset = WidgetFormatting.reset(
        resetDate,
        locale: Locale(identifier: "en_GB"),
        timeZone: formattingTimeZone,
        calendar: calendar
    )
    #expect(gbReset?.contains("29 Aug") == true)
    #expect(gbReset?.contains("09:40") == true)

    let deReset = WidgetFormatting.reset(
        resetDate,
        locale: Locale(identifier: "de_DE"),
        timeZone: formattingTimeZone,
        calendar: calendar
    )
    #expect(deReset?.contains("29") == true)
    #expect(deReset?.contains("Aug") == true)
    #expect(deReset?.contains("09:40") == true)

    #expect(WidgetFormatting.reset(nil, timeZone: formattingTimeZone, calendar: calendar) == nil)
}

@Test func accessibilityNamesProviderWindowPercentAndResetWithoutStaleSyncAge() {
    let calendar = Calendar(identifier: .gregorian)
    let label = WidgetFormatting.accessibilityLabel(
        snapshot: formattingSnapshot(),
        locale: Locale(identifier: "en_US"),
        timeZone: formattingTimeZone,
        calendar: calendar
    )
    #expect(label.contains("Codex"))
    #expect(label.contains("Weekly"))
    #expect(label.contains("17 percent remaining"))
    #expect(label.contains("resets"))
    #expect(!label.contains("synced"))

    let subOneLabel = WidgetFormatting.accessibilityLabel(
        snapshot: formattingSnapshot(percentLeft: 0.7),
        locale: Locale(identifier: "en_US"),
        timeZone: formattingTimeZone,
        calendar: calendar
    )
    #expect(subOneLabel.contains("0.7 percent remaining"))
    #expect(!subOneLabel.contains("0 percent remaining"))
    #expect(!subOneLabel.contains("synced"))

    let errorLabel = WidgetFormatting.accessibilityLabel(
        snapshot: formattingSnapshot(status: .error),
        locale: Locale(identifier: "en_US"),
        timeZone: formattingTimeZone,
        calendar: calendar
    )
    #expect(errorLabel == "Codex, usage unavailable")

    let noWindowLabel = WidgetFormatting.accessibilityLabel(
        snapshot: formattingSnapshot(selectedWindow: false),
        locale: Locale(identifier: "en_US"),
        timeZone: formattingTimeZone,
        calendar: calendar
    )
    #expect(noWindowLabel == "Codex, usage unavailable")
}

@Test func resetFormattingHandlesFractionalSecondDates() {
    let reset = WidgetFormatting.reset(
        Date(timeIntervalSince1970: 1_788_010_800.456),
        locale: Locale(identifier: "en_US"),
        timeZone: formattingTimeZone,
        calendar: Calendar(identifier: .gregorian)
    )
    #expect(reset != nil)
    #expect(reset?.contains("Aug 29") == true)
    #expect(reset?.contains("9:40") == true)
    #expect(reset?.contains("AM") == true)
}
