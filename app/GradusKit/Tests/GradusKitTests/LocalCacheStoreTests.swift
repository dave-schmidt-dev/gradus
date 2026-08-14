import Foundation
@testable import GradusKit
import Testing

private func makeTempStore() -> FileLocalCacheStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-cache-tests-\(UUID().uuidString)", isDirectory: true)
    return FileLocalCacheStore(directory: directory)
}

private func sampleStatus(name: String = "Codex") -> ProviderStatus {
    ProviderStatus(
        providerName: name,
        providerDisplayName: name,
        ok: true,
        errorMessage: nil,
        windows: [ProviderWindow(id: "weekly", percentLeft: 58.0, resetISO: nil, windowHours: 168.0, paceDelta: -0.2)],
        data: ["weekly_percent_left": .double(58.0)],
        observedAt: "2026-08-02T20:00:00-04:00",
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test func freshStoreHasNoCachedData() {
    let store = makeTempStore()
    #expect(store.loadCachedStatuses() == [])
    #expect(store.lastSyncedAt() == nil)
    #expect(store.loadChangeToken() == nil)
}

@Test func statusesAndSyncedAtRoundTrip() throws {
    let store = makeTempStore()
    let statuses = [sampleStatus(name: "Codex"), sampleStatus(name: "Claude")]
    let syncedAt = Date(timeIntervalSince1970: 1_700_000_500)

    try store.saveCachedStatuses(statuses, syncedAt: syncedAt)

    #expect(store.loadCachedStatuses() == statuses)
    #expect(store.lastSyncedAt() == syncedAt)
}

@Test func laterSaveOverwritesEarlierCache() throws {
    let store = makeTempStore()
    try store.saveCachedStatuses([sampleStatus(name: "Codex")], syncedAt: Date(timeIntervalSince1970: 1))
    try store.saveCachedStatuses([sampleStatus(name: "Claude")], syncedAt: Date(timeIntervalSince1970: 2))

    #expect(store.loadCachedStatuses() == [sampleStatus(name: "Claude")])
}

@Test func changeTokenRoundTrips() throws {
    let store = makeTempStore()
    let token = Data([0x01, 0x02, 0x03, 0xFF])

    try store.saveChangeToken(token)
    #expect(store.loadChangeToken() == token)
}

@Test func savingNilChangeTokenClearsIt() throws {
    let store = makeTempStore()
    try store.saveChangeToken(Data([0x01]))
    try store.saveChangeToken(nil)

    #expect(store.loadChangeToken() == nil)
}

@Test func clearRemovesBothCacheAndToken() throws {
    let store = makeTempStore()
    try store.saveCachedStatuses([sampleStatus()], syncedAt: Date())
    try store.saveChangeToken(Data([0x01]))

    try store.clear()

    #expect(store.loadCachedStatuses() == [])
    #expect(store.lastSyncedAt() == nil)
    #expect(store.loadChangeToken() == nil)
}
