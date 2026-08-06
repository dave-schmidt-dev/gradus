import AppKit
import SwiftUI

/// Hosts `MacSettingsView` in a window this app owns outright.
///
/// SwiftUI's `Settings` scene is the obvious way to do this and it does not
/// work here. Measured on macOS 26.5.2, in the real (non-test) app with the
/// pipeline disabled:
///
/// ```
/// sendAction(showSettingsWindow:)  -> true, and no window appears
/// sendAction(showPreferencesWindow:) -> false   (the 12-and-earlier name is gone)
/// orderFrontStandardAboutPanel:    -> opens an NSPanel   (control: dispatch works)
/// ```
///
/// The `true` is the whole problem: `sendAction` reports that *something*
/// accepted the action, so the call site cannot tell success from silence.
/// `SwiftUI.AppDelegate` answers `showSettingsWindow:` whether or not a
/// `Settings` scene is declared -- verified by deleting the scene and watching
/// `target(forAction:)` still resolve -- so even a responder-chain assertion
/// would have passed against a completely absent Settings window. Promoting an
/// agent app to `.setActivationPolicy(.regular)` first, on the theory that the
/// scene needs menu-bar context, changes nothing: still `true`, still no window.
///
/// `SettingsLink` (macOS 14+) may well work, but this app deploys to 13.0 and,
/// more to the point, a `SettingsLink` is only exercised by a real click --
/// there would be no way to gate it, which is exactly how the broken selector
/// shipped. An `NSWindow` we construct ourselves is testable: after
/// `SettingsWindow.show`, the window is in `NSApp.windows` or the test fails.
@MainActor
enum SettingsWindow {
    /// Held across closes so a second "Settings…" click re-focuses the window
    /// the user already has rather than stacking another copy on top of it.
    /// `isReleasedWhenClosed = false` below is what makes keeping this
    /// reference safe; with AppKit's default the closed window would be
    /// deallocated out from under it.
    private static var window: NSWindow?

    static let title = "Gradus Settings"

    /// Width matches `MacSettingsView`'s own `.frame(width: 420)`. The height
    /// is the hosting controller's measured `fittingSize` for that width in a
    /// running app -- not an estimate. Setting it to anything smaller is not a
    /// clipped window but a *jumping* one: the controller's constraints resize
    /// it to this height on the first layout pass, so a guess of 600 showed
    /// the user a window that snapped taller a moment after opening.
    /// Resizable regardless, so a larger text size stays readable.
    static let contentSize = NSSize(width: 420, height: 660)

    @discardableResult
    static func show(viewModel: PublisherViewModel) -> NSWindow {
        // An accessory app is not frontmost when its menu bar item is clicked,
        // so without this the window opens behind whatever the user was working
        // in -- which reads as the button doing nothing, the same symptom the
        // selector had for a different reason.
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return existing
        }

        let controller = NSHostingController(rootView: MacSettingsView(viewModel: viewModel))
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        // `NSWindow(contentViewController:)` is documented to size itself from
        // the controller, and here it produces a 1x32pt window: the hosting
        // controller has not laid out its SwiftUI content at the moment the
        // window asks. The result is a window that is genuinely on screen,
        // genuinely visible, and a single point wide -- which is why
        // `SettingsWindowTests` asserts the frame and not just existence.
        window.setContentSize(Self.contentSize)
        window.center()
        Self.window = window
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Test hook: drops the cached window so each case starts from a cold
    /// state, and closes it so a run doesn't leave windows on screen.
    static func resetForTesting() {
        window?.close()
        window = nil
    }
}
