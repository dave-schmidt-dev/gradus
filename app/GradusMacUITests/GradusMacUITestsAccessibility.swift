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
}
