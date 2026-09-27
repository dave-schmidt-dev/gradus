import Foundation
@testable import GradusKit
import Testing

private func sweepStaleCacheTestDirectories() {
    let manager = FileManager.default
    let base = manager.temporaryDirectory
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    guard let directories = try? manager.contentsOfDirectory(
        at: base,
        includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
    ) else { return }

    for directory in directories where directory.lastPathComponent.hasPrefix("gradus-cache-tests-") {
        guard let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
              values.isDirectory == true,
              let modifiedAt = values.contentModificationDate,
              modifiedAt < cutoff else { continue }

        guard let descendants = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { continue }
        var safeToRemove = true
        while let descendant = descendants.nextObject() as? URL {
            guard let descendantValues = try? descendant.resourceValues(forKeys: [.contentModificationDateKey]),
                  let descendantModifiedAt = descendantValues.contentModificationDate,
                  descendantModifiedAt < cutoff else {
                safeToRemove = false
                break
            }
        }
        if safeToRemove {
            try? manager.removeItem(at: directory)
        }
    }
}

private func withTempStore<T>(_ body: (FileLocalCacheStore, URL) throws -> T) throws -> T {
    sweepStaleCacheTestDirectories()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-cache-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(FileLocalCacheStore(directory: directory), directory)
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

private enum InjectedCacheTempError: Error { case expected }

@Test func cacheTempStoreIsRemovedAfterSuccessAndThrow() throws {
    let successfulDirectory = try withTempStore { _, directory in
        #expect(FileManager.default.fileExists(atPath: directory.path))
        return directory
    }
    #expect(!FileManager.default.fileExists(atPath: successfulDirectory.path))

    var throwingDirectory: URL?
    #expect(throws: InjectedCacheTempError.self) {
        try withTempStore { _, directory in
            throwingDirectory = directory
            throw InjectedCacheTempError.expected
        }
    }
    let removedDirectory = try #require(throwingDirectory)
    #expect(!FileManager.default.fileExists(atPath: removedDirectory.path))
}

@Test func freshStoreHasNoCachedData() throws {
    try withTempStore { store, _ in
        #expect(store.loadCachedStatuses() == [])
        #expect(store.lastSyncedAt() == nil)
        #expect(store.loadChangeToken() == nil)
    }
}

@Test func statusesAndSyncedAtRoundTrip() throws {
    try withTempStore { store, _ in
        let statuses = [sampleStatus(name: "Codex"), sampleStatus(name: "Claude")]
        let syncedAt = Date(timeIntervalSince1970: 1_700_000_500)

        try store.saveCachedStatuses(statuses, syncedAt: syncedAt)

        #expect(store.loadCachedStatuses() == statuses)
        #expect(store.lastSyncedAt() == syncedAt)
    }
}

@Test func laterSaveOverwritesEarlierCache() throws {
    try withTempStore { store, _ in
        try store.saveCachedStatuses([sampleStatus(name: "Codex")], syncedAt: Date(timeIntervalSince1970: 1))
        try store.saveCachedStatuses([sampleStatus(name: "Claude")], syncedAt: Date(timeIntervalSince1970: 2))

        #expect(store.loadCachedStatuses() == [sampleStatus(name: "Claude")])
    }
}

@Test func changeTokenRoundTrips() throws {
    try withTempStore { store, _ in
        let token = Data([0x01, 0x02, 0x03, 0xFF])

        try store.saveChangeToken(token)
        #expect(store.loadChangeToken() == token)
    }
}

@Test func savingNilChangeTokenClearsIt() throws {
    try withTempStore { store, _ in
        try store.saveChangeToken(Data([0x01]))
        try store.saveChangeToken(nil)

        #expect(store.loadChangeToken() == nil)
    }
}

@Test func clearRemovesBothCacheAndToken() throws {
    try withTempStore { store, _ in
        try store.saveCachedStatuses([sampleStatus()], syncedAt: Date())
        try store.saveChangeToken(Data([0x01]))

        try store.clear()

        #expect(store.loadCachedStatuses() == [])
        #expect(store.lastSyncedAt() == nil)
        #expect(store.loadChangeToken() == nil)
    }
}
