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

    /// The missing wake-up behind the 1.6.0 gap's worst case: a first-launch
    /// denial. `refreshNotificationAuthorization()` on `.task` races the prompt
    /// and reads `.notDetermined`, and a permission alert does not reliably
    /// send the scene back through `.active`, so without this callback someone
    /// who taps "Don't Allow" sees no warning until an unrelated foreground
    /// cycle. Holding `resolve` rather than calling it immediately checks both
    /// halves: nothing is read while the prompt is still open, and the read
    /// happens as soon as it is answered.
    @Test
    func launchRereadsPermissionOnlyOnceThePromptIsAnswered() {
        var resolve: (() -> Void)?
        let delegate = AppDelegate(clearBadge: {}, requestNotificationAuthorization: { _, resolved in
            resolve = resolved
        })
        var rereadCount = 0
        delegate.onAuthorizationResolved = { rereadCount += 1 }

        #expect(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))

        #expect(rereadCount == 0)

        resolve?()

        #expect(rereadCount == 1)
    }
}
