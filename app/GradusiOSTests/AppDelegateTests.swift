import Testing
import UIKit
@testable import GradusiOS

@MainActor
struct AppDelegateTests {
    @Test
    func clearsBadgeWhenApplicationBecomesActive() {
        var clearCount = 0
        let delegate = AppDelegate {
            clearCount += 1
        }

        delegate.applicationDidBecomeActive(UIApplication.shared)

        #expect(clearCount == 1)
    }

    @Test
    func clearsBadgeWhenApplicationReturnsToForeground() {
        var clearCount = 0
        let delegate = AppDelegate {
            clearCount += 1
        }

        delegate.applicationWillEnterForeground(UIApplication.shared)

        #expect(clearCount == 1)
    }
}
