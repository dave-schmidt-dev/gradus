import Foundation
import GradusKit
@testable import GradusMac
import Testing

@MainActor
@Test func settingsViewModelRefreshesConnectedDeviceDirectoryWithoutHistory() throws {
    let defaults = try #require(UserDefaults(suiteName: "presence-mac-\(UUID().uuidString)"))
    let viewModel = PublisherViewModel(defaults: defaults)
    let device = DevicePresence(
        installationID: "123E4567-E89B-12D3-A456-426614174000",
        displayName: .iPhone,
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    viewModel.updateConnectedDevices([device])
    #expect(viewModel.connectedDevices == [device])
    viewModel.updateConnectedDevices([])
    #expect(viewModel.connectedDevices.isEmpty)
}
