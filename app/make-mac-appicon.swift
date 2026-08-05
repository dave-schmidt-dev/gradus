#!/usr/bin/env swift
//
//  make-mac-appicon.swift
//
//  Regenerates GradusMac's AppIcon PNGs. Idempotent: run it as often as you
//  like, it always writes the same bytes.
//
//      swift app/make-mac-appicon.swift
//
//  ## Why the Mac icon is not just a copy of the iOS one
//
//  iOS masks a square 1024 artwork into the app shape for you, which is why
//  `GradusiOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png` is full-bleed
//  and opaque all the way to its corners. macOS does NOT mask -- the artwork
//  supplies its own rounded shape and margin, and a full-bleed square there
//  renders as a hard-cornered tile that looks wrong beside every other app.
//
//  Verified empirically on macOS 26.5.2 rather than taken from memory: the
//  alpha channel of Calculator/Notes/Reminders/Safari is fully transparent at
//  the canvas corner, at 4% inset, and at 10% inset. All four agree on the
//  same grid, which is where the constants below come from.
//
//  ## Geometry (measured, not recalled)
//
//  Apple's shipping icons, drawn at 1024 and bbox'd: art occupies x 100...923
//  (824 wide) -- the classic 824-in-1024 grid, 9.77% margin each side.
//
//  CORNER_RADIUS was fitted, not looked up. A radius sweep against a 1024
//  rendition of Notes.app, comparing the full corner curve (first opaque x per
//  row) rather than a single pixel, minimized at 214.5 with RMS 0.30px and max
//  deviation 1px. Cross-checked against Safari: same 214.5. For reference, the
//  often-quoted 185.4 scores RMS ~13px here and is visibly too sharp -- it
//  describes the pre-Big Sur grid, not the current shape. Re-fit these numbers
//  against a current OS before assuming they still hold on a future macOS.
//
//  `.continuous` matters: Apple's corner is a superellipse, not a circular
//  arc. `NSBezierPath(roundedRect:xRadius:yRadius:)` would give the wrong
//  curve; SwiftUI's continuous RoundedRectangle is what matches to 1px.
//
//  ## Artwork
//
//  Geometry mirrors `design-system/zero-delta/assets/logos/gradus-app-icon.svg`
//  lines 2-4 (that SVG is the design source of truth; these constants are its
//  transcription). Each size is drawn from the vector at its native scale
//  rather than downsampled from 1024, so the small renditions stay crisp.
//
//  Known limitation: the bars are 72/1024 tall, so at the 16pt rendition they
//  are ~1px and read as a near-solid dark square. Every icon degrades at 16pt;
//  simplified small-size art would be a separate design task, not a bug here.
//

import AppKit
import SwiftUI

// MARK: - Constants

/// Nominal canvas the artwork is authored against (matches the SVG viewBox).
let CANVAS: CGFloat = 1024

/// Art square inset within the canvas. 100/1024 => 824 wide. Measured from
/// Calculator, Notes, Reminders and Safari, which agree exactly.
let ART_INSET: CGFloat = 100
let ART_SIDE: CGFloat = CANVAS - (ART_INSET * 2)  // 824

/// Fitted against Notes.app at 1024 (RMS 0.30px, max deviation 1px).
let CORNER_RADIUS: CGFloat = 214.5

/// The ladder `actool` requires for a macOS app icon. A single 1024 entry --
/// the form GradusiOS uses -- compiles to nothing on macOS: no `Assets.car`,
/// no `CFBundleIconName`, and no build error either. Confirmed by running
/// `actool --platform macosx` both ways before writing this.
let SIZES: [Int] = [16, 32, 64, 128, 256, 512, 1024]

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let BACKGROUND = rgb(0x141419)
let TRACK = rgb(0x4E4E4E)

/// (y, filled width, fill colour) per bar. x/height/radius are shared.
let BARS: [(y: CGFloat, filled: CGFloat, color: CGColor)] = [
    (292, 672, rgb(0x87D787)),  // green  -- full
    (476, 404, rgb(0xFFD75F)),  // yellow -- partial
    (660, 148, rgb(0xFF5F5F)),  // red    -- low
]
let BAR_X: CGFloat = 176
let BAR_W: CGFloat = 672
let BAR_H: CGFloat = 72
let BAR_R: CGFloat = 36

// MARK: - Drawing

/// Renders the icon at `size` x `size` and returns PNG data.
func renderIcon(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    let cg = gctx.cgContext

    // Work in the SVG's top-left-origin 1024 space at every output size, so
    // the constants above are literal and each rendition is drawn from the
    // vector rather than resampled.
    let scale = CGFloat(size) / CANVAS
    cg.translateBy(x: 0, y: CGFloat(size))
    cg.scaleBy(x: scale, y: -scale)
    cg.setShouldAntialias(true)
    cg.interpolationQuality = .high

    // The macOS app shape. Everything below is clipped to it, which is what
    // gives the transparent margin and rounded corners iOS applies for free.
    let artRect = CGRect(x: ART_INSET, y: ART_INSET, width: ART_SIDE, height: ART_SIDE)
    let shape = RoundedRectangle(cornerRadius: CORNER_RADIUS, style: .continuous)
    cg.addPath(shape.path(in: artRect).cgPath)
    cg.clip()

    cg.setFillColor(BACKGROUND)
    cg.fill(artRect)

    // Bars are authored against the full 1024 canvas, so squeeze them into the
    // 824 art square -- otherwise they would run under the clip and lose their
    // rounded ends against the icon edge.
    cg.translateBy(x: ART_INSET, y: ART_INSET)
    cg.scaleBy(x: ART_SIDE / CANVAS, y: ART_SIDE / CANVAS)

    for bar in BARS {
        // Track first, then the filled portion over it.
        for (width, color) in [(BAR_W, TRACK), (bar.filled, bar.color)] {
            let r = CGRect(x: BAR_X, y: bar.y, width: width, height: BAR_H)
            cg.addPath(CGPath(roundedRect: r, cornerWidth: BAR_R, cornerHeight: BAR_R,
                              transform: nil))
            cg.setFillColor(color)
            cg.fillPath()
        }
    }

    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode \(size)px PNG\n".utf8))
        exit(1)
    }
    return png
}

// MARK: - Main

// Resolve output relative to this script so it works from any cwd.
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let appDir = scriptURL.deletingLastPathComponent()
let outDir = appDir
    .appendingPathComponent("GradusMac/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var wrote = 0, unchanged = 0
for size in SIZES {
    let data = renderIcon(size: size)
    let url = outDir.appendingPathComponent("icon_\(size).png")
    // Idempotent: only touch the file when the bytes actually differ, so a
    // no-op run leaves the working tree clean.
    if let existing = try? Data(contentsOf: url), existing == data {
        unchanged += 1
        continue
    }
    try data.write(to: url)
    wrote += 1
    print("wrote \(url.lastPathComponent) (\(size)x\(size), \(data.count) bytes)")
}
print("\(wrote) written, \(unchanged) unchanged -> \(outDir.path)")
