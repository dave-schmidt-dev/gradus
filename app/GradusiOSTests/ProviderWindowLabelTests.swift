@testable import GradusiOS
import Testing

// P4/T4.1 gate: every observed schema-v2 window id maps to a non-blank
// human label, and unknown future ids fall back to the raw string.

@Test func providerWindowLabelMapsSchemaV2Ids() {
    #expect(ProviderWindowLabel.label(for: "five_hour") == "5 Hour")
    #expect(ProviderWindowLabel.label(for: "weekly") == "Weekly")
    #expect(ProviderWindowLabel.label(for: "monthly") == "Monthly")
    #expect(ProviderWindowLabel.label(for: "premium") == "Monthly")
    #expect(ProviderWindowLabel.label(for: "ac") == "Auto")
    #expect(ProviderWindowLabel.label(for: "ap") == "API")
    #expect(ProviderWindowLabel.label(for: "cg5") == "5 Hour (CG)")
    #expect(ProviderWindowLabel.label(for: "cg1w") == "Weekly (CG)")
    #expect(ProviderWindowLabel.label(for: "cg_five_hour") == "5 Hour (CG)")
    #expect(ProviderWindowLabel.label(for: "cg_weekly") == "Weekly (CG)")
    #expect(ProviderWindowLabel.label(for: "billing_cycle") == "Monthly")
}

@Test func providerWindowLabelFallsBackToRawIdForUnknownId() {
    #expect(ProviderWindowLabel.label(for: "some_future_window_id") == "some_future_window_id")
}

@Test func providerWindowSelectionRetainsProviderAndWindowIDsVerbatim() {
    let selection = ProviderWindowSelection(providerName: "Provider Name", windowID: "schema-v2/AC")
    #expect(selection.providerName == "Provider Name")
    #expect(selection.windowID == "schema-v2/AC")
}
