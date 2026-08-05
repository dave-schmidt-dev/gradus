import AppKit
import GradusKit
import SwiftUI
import Testing

@testable import GradusMac

@MainActor
@Test func menuProgressBarPlacesMarkerAtSharedExpectedRemainingPosition() {
    let markerFraction = try! #require(
        ProgressBar.expectedRemainingMarkerFraction(percentLeft: 62, paceDelta: -0.05)
    )

    #expect(markerFraction == 0.67)
}

@MainActor
@Test func menuProviderRowWithoutPaceKeepsValueAndResetData() {
    let provider = ProviderEntry(
        name: "Codex",
        ok: true,
        error: nil,
        windows: [
            ProviderWindow(
                id: "5h",
                percentLeft: 62,
                resetISO: "2026-08-02T23:00:00Z",
                windowHours: 5,
                paceDelta: nil
            )
        ],
        data: [:],
        observedAt: "2026-08-02T17:55:00Z"
    )

    let markerFraction = ProgressBar.expectedRemainingMarkerFraction(
        percentLeft: provider.windows[0].percentLeft,
        paceDelta: provider.windows[0].paceDelta
    )

    #expect(markerFraction == nil)
    #expect(provider.windows[0].percentLeft == 62)
    #expect(provider.windows[0].resetISO == "2026-08-02T23:00:00Z")
}
