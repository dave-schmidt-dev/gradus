import AppKit
import Testing

/// Locks the app icon into the built bundle.
///
/// GradusMac shipped with no icon at all for its whole life before this: the
/// target had no asset catalog and no `ASSETCATALOG_COMPILER_APPICON_NAME`, so
/// `Contents/Resources` came out empty and the Info.plist had no icon key.
/// macOS fell back to the generic placeholder. Nothing caught it -- `actool`
/// emits no warning for an app icon that was never requested, and
/// `INFOPLIST_KEY_LSUIElement: YES` means there is no Dock icon to notice it
/// missing from. It only surfaced in Finder, Login Items, notification
/// banners, and TCC permission prompts.
///
/// These run in the host app process (`TEST_HOST`), so `Bundle.main` is
/// GradusMac.app itself and every assertion below is against the real built
/// artifact rather than a fixture.
@Suite("App icon")
struct AppIconTests {
    /// The keys Finder/TCC/Notification Center actually read.
    @Test func bundleDeclaresAnIcon() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String
        #expect(name == "AppIcon", "CFBundleIconName missing -- ASSETCATALOG_COMPILER_APPICON_NAME unset?")
        let file = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
        #expect(file == "AppIcon")
    }

    /// A catalog can compile while still producing no `.icns` (the single-1024
    /// iOS-style entry does exactly that on macOS -- silently, no build error).
    /// Assert the compiled artifact itself, not just the plist key.
    @Test func compiledIcnsIsPresentAndLoadable() throws {
        let url = try #require(
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            "no AppIcon.icns in the bundle"
        )
        let image = try #require(NSImage(contentsOf: url), "AppIcon.icns did not decode")
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    /// The regression this exists for: someone "fixes" the Mac icon by copying
    /// `GradusiOS`'s `icon-1024.png` across. That artwork is full-bleed and
    /// opaque to its corners because iOS masks it into the app shape at render
    /// time. macOS does not mask, so the copy renders as a hard-cornered tile.
    ///
    /// Measured against macOS 26.5.2's own icons (Calculator, Notes, Reminders,
    /// Safari -- all identical): art occupies the centre 824 of a 1024 canvas,
    /// leaving a 9.77% transparent margin, and the corners are a superellipse.
    /// Sampling the corner and the 4% inset distinguishes the two cases
    /// unambiguously without pinning an exact curve.
    @Test func artworkHasTheMacOSShapeNotTheIOSSquare() throws {
        let url = try #require(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
        let image = try #require(NSImage(contentsOf: url))

        let side = 1024
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        func alpha(_ x: Int, _ y: Int) -> CGFloat {
            rep.colorAt(x: x, y: y)?.alphaComponent ?? -1
        }

        // Outside the rounded shape: must be cut away, not painted.
        #expect(alpha(0, 0) == 0, "corner is opaque -- full-bleed iOS artwork, not a macOS icon")
        #expect(alpha(side * 4 / 100, side * 4 / 100) == 0, "no transparent margin at 4% inset")
        #expect(alpha(side - 1, side - 1) == 0, "opposite corner is opaque")

        // Inside: the artwork itself must actually be there.
        #expect(alpha(side / 2, side / 2) > 0.99, "icon centre is not opaque")
        // Just inside the 100px margin, well clear of the corner curve.
        #expect(alpha(side / 2, 110) > 0.99, "top edge of the art square is missing")
    }
}
