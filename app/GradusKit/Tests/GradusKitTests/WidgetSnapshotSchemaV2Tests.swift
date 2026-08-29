import Foundation
@testable import GradusKit
import Testing

private let schemaV2ReferenceDate = Date(timeIntervalSince1970: 1_785_000_000)

private func schemaV2Provider(_ name: String, _ displayName: String) -> WidgetProviderSnapshot {
    WidgetProviderSnapshot(
        providerName: name,
        providerDisplayName: displayName,
        status: .ok,
        selectedWindow: WidgetWindowSnapshot(
            id: "weekly",
            label: "Weekly",
            percentLeft: 42,
            signalLevel: .yellow,
            resetDate: schemaV2ReferenceDate.addingTimeInterval(3600)
        )
    )
}

@Test func widgetSnapshotRoundTripsThreeProviders() throws {
    let original = WidgetSnapshot(
        phoneSyncDate: schemaV2ReferenceDate,
        providers: [
            schemaV2Provider("codex", "Codex"),
            schemaV2Provider("claude", "Claude"),
            schemaV2Provider("opencode-go", "OpenCode Go")
        ]
    )
    let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(original))

    #expect(decoded == original)
    #expect(decoded.providers.map(\.providerName) == ["codex", "claude", "opencode-go"])
    #expect(decoded.providerName == "codex")
}

@Test func widgetSnapshotDecodesLegacySingleProviderPayload() throws {
    let legacy = WidgetSnapshot(
        schemaVersion: 1,
        phoneSyncDate: schemaV2ReferenceDate,
        providerName: "codex",
        providerDisplayName: "Codex",
        status: .ok,
        selectedWindow: nil
    )
    let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(legacy))

    #expect(decoded.schemaVersion == 1)
    #expect(decoded.providers.count == 1)
    #expect(decoded.providerName == "codex")
}

@Test func widgetSnapshotRejectsInvalidVersionTwoProviderCounts() throws {
    let provider = """
    {"provider_name":"codex","provider_display_name":"Codex","status":"ok"}
    """
    for count in [0, 4] {
        let providers = Array(repeating: provider, count: count).joined(separator: ",")
        let json = """
        {"schema_version":2,"phone_sync_date":\(schemaV2ReferenceDate.timeIntervalSinceReferenceDate),
        "providers":[\(providers)]}
        """
        let data = try #require(json.data(using: .utf8))
        #expect(throws: WidgetSnapshotDecodeError.invalidProviderCount(count)) {
            try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        }
    }
}
