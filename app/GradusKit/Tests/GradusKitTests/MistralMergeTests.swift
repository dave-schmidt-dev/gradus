import Foundation
@testable import GradusKit
import Testing

private func entry(
    _ name: String,
    ok: Bool = true,
    windowID: String? = nil,
    percentLeft: Double = 50,
    observedAt: String? = "2026-09-30T08:00:00-04:00",
    error: String? = nil
) -> ProviderEntry {
    let windows = windowID.map {
        [ProviderWindow(
            id: $0, percentLeft: percentLeft, resetISO: "2026-10-01T00:00:00-04:00",
            windowHours: 720, paceDelta: 0
        )]
    } ?? []
    return ProviderEntry(
        name: name, ok: ok, error: error, windows: windows, data: [:], observedAt: observedAt
    )
}

@Test func mistralEntriesMergeIntoOneCardWithTwoLabelledWindows() {
    let merged = MistralMerge.merge([
        entry("Codex"),
        entry("Vibe Code", windowID: "billing_cycle", percentLeft: 33.7),
        entry("Vibe", windowID: "api_billing", percentLeft: 0)
    ])
    #expect(merged.map(\.name) == ["Codex", "Mistral"])
    let mistral = merged[1]
    #expect(mistral.ok)
    // API first regardless of file order; the shared billing_cycle id is renamed.
    #expect(mistral.windows.map(\.id) == ["api_billing", "vibe_billing"])
    #expect(mistral.windows.map(\.percentLeft) == [0, 33.7])
    #expect(mistral.windows.map { normalizedWidgetWindowLabel(for: $0.id) } == ["API", "Vibe"])
}

@Test func mergedCardKeepsTheFirstMemberPosition() {
    let merged = MistralMerge.merge([
        entry("Claude"),
        entry("Vibe", windowID: "api_billing"),
        entry("Cursor"),
        entry("Vibe Code", windowID: "billing_cycle")
    ])
    #expect(merged.map(\.name) == ["Claude", "Mistral", "Cursor"])
}

@Test func aFailedAllowanceContributesNoWindow() {
    let merged = MistralMerge.merge([
        entry("Vibe", ok: false, error: "boom"),
        entry("Vibe Code", windowID: "billing_cycle")
    ])
    #expect(merged.count == 1)
    #expect(merged[0].ok)
    #expect(merged[0].error == nil)
    #expect(merged[0].windows.map(\.id) == ["vibe_billing"])
}

@Test func bothAllowancesFailingIsOneErrorCard() {
    let merged = MistralMerge.merge([
        entry("Vibe", ok: false, error: "api down"),
        entry("Vibe Code", ok: false, error: "code down")
    ])
    #expect(merged.count == 1)
    #expect(!merged[0].ok)
    #expect(merged[0].error == "api down")
    #expect(merged[0].windows.isEmpty)
}

@Test func cardIsAsFreshAsItsStalestHealthyAllowance() {
    let merged = MistralMerge.merge([
        entry("Vibe", windowID: "api_billing", observedAt: "2026-09-30T08:00:00-04:00"),
        entry("Vibe Code", windowID: "billing_cycle", observedAt: "2026-09-30T07:00:00-04:00")
    ])
    #expect(merged[0].observedAt == "2026-09-30T07:00:00-04:00")
}

@Test func snapshotsWithoutMistralEntriesAreUntouched() {
    let providers = [entry("Codex"), entry("Cursor")]
    #expect(MistralMerge.merge(providers) == providers)
}

@Test func legacySingleVibeEntryStillBecomesAMistralCard() {
    // Older monitors published one "Vibe" entry carrying the Vibe Code window.
    let merged = MistralMerge.merge([entry("Vibe", windowID: "billing_cycle")])
    #expect(merged.map(\.name) == ["Mistral"])
    #expect(merged[0].windows.map(\.id) == ["vibe_billing"])
}
