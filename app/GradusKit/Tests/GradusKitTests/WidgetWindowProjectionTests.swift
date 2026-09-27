import Foundation
@testable import GradusKit
import Testing

// MARK: - Window Label Normalization & Projection

@Test func normalizedWidgetWindowLabelNormalizesCanonicalIDsAndRetainsUnknown() {
    #expect(normalizedWidgetWindowLabel(for: "five_hour") == "5 Hour")
    #expect(normalizedWidgetWindowLabel(for: "weekly") == "Weekly")
    #expect(normalizedWidgetWindowLabel(for: "monthly") == "Monthly")
    #expect(normalizedWidgetWindowLabel(for: "premium") == "Monthly")
    #expect(normalizedWidgetWindowLabel(for: "ac") == "Auto")
    #expect(normalizedWidgetWindowLabel(for: "ap") == "API")
    #expect(normalizedWidgetWindowLabel(for: "cg5") == "5 Hour (CG)")
    #expect(normalizedWidgetWindowLabel(for: "cg1w") == "Weekly (CG)")
    #expect(normalizedWidgetWindowLabel(for: "cg_five_hour") == "5 Hour (CG)")
    #expect(normalizedWidgetWindowLabel(for: "cg_weekly") == "Weekly (CG)")
    #expect(normalizedWidgetWindowLabel(for: "billing_cycle") == "Monthly")
    #expect(normalizedWidgetWindowLabel(for: "custom_window_99") == "custom_window_99")
}

@Test func widgetWindowSnapshotProjectsNormalizedLabelAndResetDate() {
    let iso = "2026-08-23T21:30:00-04:00"
    let window = ProviderWindow(id: "five_hour", percentLeft: 50.0, resetISO: iso, windowHours: 5.0, paceDelta: 0.0)
    let projection = WidgetWindowSnapshot(from: window)

    #expect(projection.id == "five_hour")
    #expect(projection.label == "5 Hour")
    #expect(projection.percentLeft == 50.0)
    #expect(projection.signalLevel == .green)
    #expect(projection.resetDate != nil)
}

@Test func widgetWindowSnapshotParsesFractionalSecondResetTimestamps() {
    let fractionalZ = "2026-08-23T21:30:00.123Z"
    let windowZ = ProviderWindow(
        id: "five_hour", percentLeft: 50.0, resetISO: fractionalZ, windowHours: 5.0, paceDelta: 0.0
    )
    let projectionZ = WidgetWindowSnapshot(from: windowZ)
    #expect(projectionZ.resetDate != nil)
    #expect(projectionZ.resetDate?.timeIntervalSince1970 == 1_787_520_600.123)

    let fractionalOffset = "2026-08-23T21:30:00.500-04:00"
    let windowOffset = ProviderWindow(
        id: "five_hour", percentLeft: 50.0, resetISO: fractionalOffset, windowHours: 5.0, paceDelta: 0.0
    )
    let projectionOffset = WidgetWindowSnapshot(from: windowOffset)
    #expect(projectionOffset.resetDate != nil)
    #expect(projectionOffset.resetDate?.timeIntervalSince1970 == 1_787_535_000.5)

    let invalidISO = "not-a-valid-date"
    let windowInvalid = ProviderWindow(
        id: "five_hour", percentLeft: 50.0, resetISO: invalidISO, windowHours: 5.0, paceDelta: 0.0
    )
    let projectionInvalid = WidgetWindowSnapshot(from: windowInvalid)
    #expect(projectionInvalid.resetDate == nil)
}
