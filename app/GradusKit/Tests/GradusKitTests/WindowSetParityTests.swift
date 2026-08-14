@testable import GradusKit
import Testing

/// The Mac menu and iOS dense card consume the same schema-v2 window array.
/// Keep this model-level contract separate from the Mac snapshot: the package
/// test proves the source set, while the Mac snapshot proves the view renders
/// that set rather than selecting one member.
@Suite("Window-set parity")
struct WindowSetParityTests {
    @Test func macAndIOSDeriveTheSameWindowSetFromOneSnapshot() {
        let provider = ProviderEntry(
            name: "Codex",
            ok: true,
            error: nil,
            windows: [
                ProviderWindow(
                    id: "five_hour",
                    percentLeft: 62,
                    resetISO: "2026-08-02T23:00:00Z",
                    windowHours: 5,
                    paceDelta: -0.05
                ),
                ProviderWindow(
                    id: "weekly",
                    percentLeft: 74,
                    resetISO: "2026-08-09T12:00:00Z",
                    windowHours: 168,
                    paceDelta: 0.03
                ),
                ProviderWindow(
                    id: "monthly",
                    percentLeft: 88,
                    resetISO: "2026-09-01T00:00:00Z",
                    windowHours: 720,
                    paceDelta: 0.01
                ),
                ProviderWindow(
                    id: "premium",
                    percentLeft: 41,
                    resetISO: "2026-08-03T01:00:00Z",
                    windowHours: 5,
                    paceDelta: -0.12
                )
            ],
            data: [:],
            observedAt: "2026-08-02T17:55:00Z"
        )

        let macWindowIDs = provider.windows.map(\.id)
        let iosWindowIDs = provider.windows
            .filter { percentIsValid($0.percentLeft) }
            .map(\.id)

        #expect(macWindowIDs == iosWindowIDs)
        #expect(Set(macWindowIDs) == Set(["five_hour", "weekly", "monthly", "premium"]))
    }
}
