import Testing

@testable import GradusiOS

// P4/T4.1 gate: each of the 6 plan-confirmed ids maps correctly, the
// separately-verified Cursor/Vibe ids (see `ProviderWindowLabel.swift`'s
// doc comment) map correctly, and an unknown id falls back to the raw
// string rather than crashing or rendering blank.

@Test func providerWindowLabelMapsConfirmedIds() {
    #expect(ProviderWindowLabel.label(for: "five_hour") == "5 Hour")
    #expect(ProviderWindowLabel.label(for: "weekly") == "Weekly")
    #expect(ProviderWindowLabel.label(for: "monthly") == "Monthly")
    #expect(ProviderWindowLabel.label(for: "premium") == "Premium")
    #expect(ProviderWindowLabel.label(for: "cg_five_hour") == "5 Hour (CG)")
    #expect(ProviderWindowLabel.label(for: "cg_weekly") == "Weekly (CG)")
}

@Test func providerWindowLabelMapsVerifiedCursorAndVibeIds() {
    #expect(ProviderWindowLabel.label(for: "ac") == "Auto")
    #expect(ProviderWindowLabel.label(for: "ap") == "API")
    #expect(ProviderWindowLabel.label(for: "billing_cycle") == "Billing Cycle")
}

@Test func providerWindowLabelFallsBackToRawIdForUnknownId() {
    #expect(ProviderWindowLabel.label(for: "some_future_window_id") == "some_future_window_id")
}
