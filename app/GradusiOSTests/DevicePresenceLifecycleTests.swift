import Foundation
@testable import GradusiOS
import GradusKit
import Testing

private actor LifecyclePresenceClient: DevicePresenceClient {
    var records: [DevicePresence] = []
    var deletedIDs: [String] = []

    func upsert(_ presence: DevicePresence) async throws {
        records.removeAll { $0.installationID == presence.installationID }
        records.append(presence)
    }

    func delete(installationID: String) async throws {
        deletedIDs.append(installationID)
        records.removeAll { $0.installationID == installationID }
    }

    func fetchAll() async throws -> [DevicePresence] {
        records
    }

    func subscribe() async throws {}
}

@MainActor
@Test func lifecycleSuppressesOfflineSampleAndMigrationRecoveryWrites() async {
    let client = LifecyclePresenceClient()
    let lifecycle = DevicePresenceLifecycle(client: client)
    #expect(await !lifecycle.renewNow(liveMode: false, accountAvailable: true, sampleMode: false))
    #expect(await !lifecycle.renewNow(liveMode: true, accountAvailable: false, sampleMode: false))
    #expect(await !lifecycle.renewNow(liveMode: true, accountAvailable: true, sampleMode: true))
    #expect(
        await !lifecycle.renewNow(
            liveMode: true, accountAvailable: true, sampleMode: false, migrationRecovery: true
        )
    )
    #expect(await client.records.isEmpty)
}

@MainActor
@Test func lifecycleWritesForegroundLeaseAndRemovesOnStop() async {
    let client = LifecyclePresenceClient()
    let lifecycle = DevicePresenceLifecycle(client: client)
    #expect(await lifecycle.renewNow(liveMode: true, accountAvailable: true, sampleMode: false))
    #expect(await (client.records).count == 1)
    #expect(await lifecycle.removeNow())
    #expect(await client.records.isEmpty)
    #expect(await (client.deletedIDs).count == 1)
}
