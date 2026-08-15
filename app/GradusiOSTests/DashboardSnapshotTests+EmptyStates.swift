@testable import GradusiOS
import GradusKit
import XCTest

// Empty-state and iCloud recovery coverage for DashboardSnapshotTests, split
// out here to keep DashboardSnapshotTests.swift under SwiftLint's
// file_length limit. Shares fixtures with that file via
// DashboardSnapshotFixtures.swift. The empty-state image assertions stay in
// DashboardSnapshotTests.swift itself -- see that file's header comment for
// why.

extension DashboardSnapshotTests {
    func testICloudRecoveryActionsDoNotOpenAppSettings() {
        XCTAssertEqual(EmptyStateView.actionTitle(for: .notSignedIn), "Try Again")
        XCTAssertEqual(EmptyStateView.actionTitle(for: .tryAgain), "Try Again")
        XCTAssertEqual(EmptyStateView.actionTitle(for: .restricted), "Try Again")
        XCTAssertEqual(EmptyStateView.actionTitle(for: .syncDisabled), "Continue")
        XCTAssertEqual(EmptyStateView.actionTitle(for: .awaitingConfirmation), "Continue")
    }

    /// The temporary-unavailable state stays separate from confirmed no-account
    /// and restricted states. These state-level assertions complement the image
    /// baselines without requiring a live CloudKit account in a snapshot test.
    func testTemporaryUnavailableAndRestrictedICloudRecoveryActionsStayDistinct() {
        XCTAssertEqual(DashboardContent.iCloudRecoveryAction(for: .tryAgain), .retryLiveLifecycle)
        XCTAssertEqual(DashboardContent.iCloudRecoveryAction(for: .notSignedIn), .retryLiveLifecycle)
        XCTAssertEqual(DashboardContent.iCloudRecoveryAction(for: .restricted), .retryLiveLifecycle)
        XCTAssertNotEqual(DashboardContent.iCloudRecoveryAction(for: .tryAgain), .confirmRequiredICloud)
    }

    @MainActor
    func testICloudRetryStartsFreshLifecycle() {
        let viewModel = makeViewModel(providers: [])
        var retryCount = 0
        let dashboard = DashboardContent(
            viewModel: viewModel,
            now: dashboardSnapshotFixedNow,
            layout: .denseSingleColumn,
            onRetryICloud: { retryCount += 1 }
        )

        XCTAssertEqual(DashboardContent.iCloudRecoveryAction(for: .awaitingConfirmation), .confirmRequiredICloud)
        XCTAssertEqual(DashboardContent.iCloudRecoveryAction(for: .tryAgain), .retryLiveLifecycle)
        XCTAssertEqual(DashboardContent.iCloudRecoveryAction(for: .notSignedIn), .retryLiveLifecycle)
        XCTAssertEqual(DashboardContent.iCloudRecoveryAction(for: .restricted), .retryLiveLifecycle)

        dashboard.performICloudRecovery(for: .notSignedIn)

        XCTAssertEqual(retryCount, 1)
    }
}
