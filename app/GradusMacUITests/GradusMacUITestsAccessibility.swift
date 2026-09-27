// The Accessibility and CoreGraphics plumbing the menu UI tests drive the app
// through: element traversal, attribute reads, synthetic presses, and
// window-exact screenshots. Split out of `GradusMacUITests.swift` to keep both
// files inside the length limits; the tests themselves stay there.

import ApplicationServices
import CoreGraphics
import Foundation
import XCTest

extension GradusMacUITests {
    func descendants(of root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var pending = [root]
        while !pending.isEmpty, result.count < 10000 {
            let element = pending.removeFirst()
            result.append(element)
            pending.append(contentsOf: elements(element, kAXChildrenAttribute as String))
        }
        return result
    }

    func accessibleStrings(of element: AXUIElement) -> Set<String> {
        let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
        return Set(names.compactMap { attribute(element, $0 as String) as String? })
    }

    /// Finds a control by its `accessibilityIdentifier`.
    ///
    /// Title matching does not work for `Form` rows: SwiftUI renders the label
    /// as a sibling `AXStaticText` and leaves the control's `AXTitle` empty, so
    /// a checkbox in Settings is unreachable by name. The identifier is set in
    /// the view and is the same string in both places.
    func findElement(
        descendingFrom root: AXUIElement,
        role: String? = nil,
        identifier: String
    ) -> AXUIElement? {
        descendants(of: root).first { element in
            guard attribute(element, "AXIdentifier") as String? == identifier else { return false }
            guard let role else { return true }
            return attribute(element, kAXRoleAttribute as String) as String? == role
        }
    }

    func requiredElement(
        descendingFrom root: AXUIElement,
        role: String? = nil,
        identifier: String
    ) throws -> AXUIElement {
        guard let element = findElement(descendingFrom: root, role: role, identifier: identifier) else {
            throw HarnessError.failed(
                "Missing Accessibility element id=\(identifier) role=\(role ?? "any")"
            )
        }
        return element
    }

    func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID()
        else {
            return []
        }
        let array = unsafeBitCast(value, to: CFArray.self)
        return (0 ..< CFArrayGetCount(array)).map { index in
            unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: AXUIElement.self)
        }
    }

    func position(of element: AXUIElement) throws -> CGPoint {
        guard let value: AXValue = attribute(element, kAXPositionAttribute as String),
              AXValueGetType(value) == .cgPoint
        else {
            throw HarnessError.failed("Accessibility element did not expose a CGPoint position")
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else {
            throw HarnessError.failed("Could not decode Accessibility element position")
        }
        return point
    }

    func performPress(on element: AXUIElement) throws {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else {
            throw HarnessError.failed("Accessibility press failed with AXError \(result.rawValue)")
        }
    }

    func attachWindowScreenshot(
        window: AXUIElement,
        ownerPID: pid_t,
        title: String,
        name: String
    ) throws {
        guard ProcessInfo.processInfo.environment["GRADUS_MAC_UI_SCREENSHOTS"] == "1" else {
            print("STATUS GradusMacAXHarness screenshot capture skipped (GRADUS_MAC_UI_SCREENSHOTS is not 1)")
            return
        }

        let windowID = try waitForWindowID(
            window: window, ownerPID: ownerPID, title: title, timeout: 1
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gradus-window-\(ownerPID)-\(windowID)-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(windowID)", outputURL.path]
        print("STATUS GradusMacAXHarness capture pid=\(ownerPID) title=\(title) windowID=\(windowID)")
        try capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0 else {
            throw HarnessError.failed("screencapture failed for exact window ID \(windowID)")
        }

        let data = try Data(contentsOf: outputURL)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func waitForWindowID(
        window: AXUIElement,
        ownerPID: pid_t,
        title: String,
        timeout: TimeInterval
    ) throws -> CGWindowID {
        guard attribute(window, kAXRoleAttribute as String) as String? == kAXWindowRole as String,
              accessibleStrings(of: window).contains(title)
        else {
            throw HarnessError.failed("Screenshot source was not the verified AX window titled \(title)")
        }
        let nativeWindowID = (attribute(window, Self.axWindowNumberAttribute) as NSNumber?)
            .map { CGWindowID($0.uint32Value) }
            .flatMap { $0 == kCGNullWindowID ? nil : $0 }
        let axFrame = try nativeWindowID == nil ? frame(of: window) : nil
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let nativeWindowID, windowOwnerPID(nativeWindowID) == ownerPID {
                return nativeWindowID
            }
            if let axFrame {
                let matches = matchingWindowIDs(ownerPID: ownerPID, frame: axFrame)
                if matches.count == 1, let match = matches.first {
                    return match
                }
                if matches.count > 1 {
                    throw HarnessError.failed(
                        "AX frame lookup was ambiguous for retained PID \(ownerPID) title \(title)"
                    )
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw HarnessError.failed(
            "Verified AX window titled \(title) did not map to a unique window owned by retained PID \(ownerPID)"
        )
    }

    func frame(of element: AXUIElement) throws -> CGRect {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute as String),
              AXValueGetType(positionValue) == .cgPoint,
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute as String),
              AXValueGetType(sizeValue) == .cgSize
        else {
            throw HarnessError.failed("Verified AX window did not expose a position and size")
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else {
            throw HarnessError.failed("Could not decode the verified AX window frame")
        }
        return CGRect(origin: origin, size: size)
    }

    func matchingWindowIDs(ownerPID: pid_t, frame: CGRect) -> [CGWindowID] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]]
        else {
            return []
        }
        return windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let cgFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  sameGlobalLogicalFrame(frame, cgFrame),
                  let number = window[kCGWindowNumber as String] as? NSNumber
            else {
                return nil
            }
            return CGWindowID(number.uint32Value)
        }
    }

    func sameGlobalLogicalFrame(_ axFrame: CGRect, _ cgFrame: CGRect) -> Bool {
        // AX and CGWindowList both report top-left global logical coordinates;
        // backing-scale conversion would double Retina dimensions. Allow only
        // sub-point serialization/rounding drift.
        let tolerance: CGFloat = 1
        return abs(axFrame.minX - cgFrame.minX) <= tolerance
            && abs(axFrame.minY - cgFrame.minY) <= tolerance
            && abs(axFrame.width - cgFrame.width) <= tolerance
            && abs(axFrame.height - cgFrame.height) <= tolerance
    }

    func windowOwnerPID(_ windowID: CGWindowID) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)
            as? [[String: Any]],
            let window = windows.first,
            (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
        else {
            return nil
        }
        return (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    }

    func waitForElement(
        descendingFrom root: AXUIElement,
        role: String? = nil,
        title: String,
        timeout: TimeInterval
    ) throws -> AXUIElement {
        try requireAccessibilityTrust()
        let deadline = Date().addingTimeInterval(timeout)
        print("STATUS GradusMacAXHarness waiting role=\(role ?? "any") title=\(title)")
        repeat {
            if let element = findElement(descendingFrom: root, role: role, title: title) {
                return element
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw HarnessError.failed("Timed out waiting for Accessibility element \(title)")
    }

    private func requireAccessibilityTrust() throws {
        guard !AXIsProcessTrusted() else { return }
        if !Self.requestedAccessibilityTrust {
            Self.requestedAccessibilityTrust = true
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        throw HarnessError.failed(
            "GradusMacUITests-Runner is not enabled in System Settings > Privacy & Security > Accessibility"
        )
    }

    func requiredElement(
        descendingFrom root: AXUIElement,
        role: String? = nil,
        title: String
    ) throws -> AXUIElement {
        guard let element = findElement(descendingFrom: root, role: role, title: title) else {
            throw HarnessError.failed("Missing Accessibility element role=\(role ?? "any") title=\(title)")
        }
        return element
    }

    func findElement(
        descendingFrom root: AXUIElement,
        role: String? = nil,
        title: String
    ) -> AXUIElement? {
        descendants(of: root).first { element in
            if let role, attribute(element, kAXRoleAttribute as String) as String? != role {
                return false
            }
            return accessibleStrings(of: element).contains(title)
        }
    }
}

extension GradusMacUITests {
    /// Opens the Settings Display picker and chooses `choice` by name.
    ///
    /// The picker is reached by identifier, not by title: the `Form` row renders
    /// "Menu bar" as a sibling `AXStaticText` and leaves the popup button's own
    /// `AXTitle` empty, exactly as this harness documents for the Settings
    /// checkboxes.
    ///
    /// A press issued while a previously opened menu is still on screen opens
    /// nothing, so the open and the choice are both bracketed by a wait for that
    /// menu to be gone. One press is then enough. The earlier version pressed
    /// repeatedly until an item showed up, which hid the ordering instead of
    /// establishing it, and turned a real failure into a timeout.
    func selectMenuBarDisplay(
        _ choice: String,
        in settingsWindow: AXUIElement,
        of fixture: RunningFixture
    ) throws {
        try awaitDisplayMenuClosed(of: fixture, timeout: 5)
        let picker = try requiredElement(
            descendingFrom: settingsWindow,
            role: kAXPopUpButtonRole as String,
            identifier: "settings-menu-bar-display"
        )
        try performPress(on: picker)
        guard let item = awaitMenuItem(named: choice, of: fixture, timeout: 5) else {
            throw HarnessError.failed(
                "Menu bar display picker never offered \(choice); it exposed \(described(picker))"
            )
        }
        try performPress(on: item)
        try awaitDisplayMenuClosed(of: fixture, timeout: 5)
    }

    func awaitMenuItem(
        named title: String,
        of fixture: RunningFixture,
        timeout: TimeInterval
    ) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let item = findElement(
                descendingFrom: fixture.application,
                role: kAXMenuItemRole as String,
                title: title
            ) {
                return item
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return nil
    }

    /// Waits until this picker's menu is off screen.
    ///
    /// A closed popup exposes none of its items: probed with the menu shut and
    /// "Codex / Weekly" already selected, neither that title nor "Gauge" was an
    /// `AXMenuItem` anywhere under the app, and all 199 menu elements then in the
    /// tree belonged to the main menu bar. "Gauge" is always one of this picker's
    /// items and is not a menu item anywhere else, so its absence is the signal.
    private func awaitDisplayMenuClosed(of fixture: RunningFixture, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if findElement(
                descendingFrom: fixture.application,
                role: kAXMenuItemRole as String,
                title: "Gauge"
            ) == nil {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw HarnessError.failed("Menu bar display picker menu stayed open past \(timeout)s")
    }

    /// Roles and names under `element`, so a miss names what was there instead.
    private func described(_ element: AXUIElement) -> String {
        let rows = descendants(of: element).prefix(20).map { child in
            let role = attribute(child, kAXRoleAttribute as String) as String? ?? "?"
            return "\(role)[\(accessibleStrings(of: child).sorted().joined(separator: "|"))]"
        }
        return rows.isEmpty ? "no descendants" : rows.joined(separator: " ")
    }
}
