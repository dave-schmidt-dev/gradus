import Foundation
@testable import GradusKit
import Testing

private func status(_ name: String, ok: Bool = true) -> ProviderStatus {
    ProviderStatus(
        providerName: name, providerDisplayName: name, ok: ok, errorMessage: nil, windows: [], data: [:],
        observedAt: nil, snapshotUpdatedAt: "2026-10-07T09:00:00-04:00",
        publishedAt: Date(timeIntervalSince1970: 1_791_000_000)
    )
}

@Test func uniquedByProviderNameKeepsLastStatusInFirstSeenOrder() {
    let result = [status("claude", ok: false), status("codex"), status("claude")].uniquedByProviderName()

    #expect(result.map(\.providerName) == ["claude", "codex"])
    #expect(result.first?.ok == true)
}

@Test func uniquedByProviderNameLeavesUniqueListsUnchanged() {
    let input = [status("codex"), status("cursor")]

    #expect(input.uniquedByProviderName().map(\.providerName) == ["codex", "cursor"])
    #expect([ProviderStatus]().uniquedByProviderName().isEmpty)
}
