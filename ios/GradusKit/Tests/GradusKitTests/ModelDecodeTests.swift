import Foundation
import Testing

@testable import GradusKit

private func loadGoldenFixtureData() throws -> Data {
    let url = Bundle.module.url(forResource: "golden-v2-snapshot", withExtension: "json")!
    return try Data(contentsOf: url)
}

@Test func decodesGoldenFixtureWithAllProviders() throws {
    let payload = try JSONDecoder().decode(SnapshotPayload.self, from: try loadGoldenFixtureData())
    #expect(payload.schemaVersion == 2)
    // 7 canonical providers + the synthetic "Antigravity (Claude)" v2-only entry.
    #expect(payload.providers.count == 8)
    let names = Set(payload.providers.map(\.name))
    #expect(
        names == [
            "Codex", "Claude", "Antigravity", "Antigravity (Claude)", "Copilot", "Cursor",
            "OpenCode Go", "Vibe",
        ])
}

@Test func decodesUnknownTopLevelAndPerProviderFieldsWithoutError() throws {
    let json = """
    {
      "schema_version": 2,
      "updated_at": "2026-08-02T20:00:00-04:00",
      "future_top_level_field": "ignored",
      "providers": [
        {
          "name": "Codex",
          "ok": true,
          "error": null,
          "windows": [],
          "data": {},
          "observed_at": "2026-08-02T20:00:00-04:00",
          "future_provider_field": 42
        }
      ]
    }
    """
    let payload = try JSONDecoder().decode(SnapshotPayload.self, from: Data(json.utf8))
    #expect(payload.providers.count == 1)
}

@Test func rejectsWrongSchemaVersion() throws {
    let json = """
    {"schema_version": 1, "updated_at": "2026-08-02T20:00:00-04:00", "providers": []}
    """
    #expect(throws: SnapshotDecodeError.unsupportedSchemaVersion(1)) {
        try JSONDecoder().decode(SnapshotPayload.self, from: Data(json.utf8))
    }
}

@Test func rejectsFutureSchemaVersionToo() throws {
    let json = """
    {"schema_version": 3, "updated_at": "2026-08-02T20:00:00-04:00", "providers": []}
    """
    #expect(throws: SnapshotDecodeError.unsupportedSchemaVersion(3)) {
        try JSONDecoder().decode(SnapshotPayload.self, from: Data(json.utf8))
    }
}

@Test func inv3BoundsHoldAcrossGoldenFixtureWindows() throws {
    let payload = try JSONDecoder().decode(SnapshotPayload.self, from: try loadGoldenFixtureData())
    for provider in payload.providers {
        for window in provider.windows {
            #expect(window.percentLeft.isFinite)
            #expect(window.percentLeft >= 0.0 && window.percentLeft <= 100.0)
        }
    }
}

@Test func carriesObservedAtSeparatelyFromOkFlag() throws {
    let payload = try JSONDecoder().decode(SnapshotPayload.self, from: try loadGoldenFixtureData())
    let copilot = payload.providers.first { $0.name == "Copilot" }!
    #expect(copilot.ok == false)
    #expect(copilot.observedAt == nil)

    let codex = payload.providers.first { $0.name == "Codex" }!
    #expect(codex.ok == true)
    #expect(codex.observedAt != nil)
}
