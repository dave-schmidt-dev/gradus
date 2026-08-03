import SwiftUI

/// Tappable icon wrapper (P2/T2.4): the rendered tap target is always
/// >= 44x44pt -- the design system's own "44px iOS tap targets" layout
/// metric -- regardless of the icon glyph's intrinsic size. The glyph
/// itself can be (and usually is) smaller; it's centered inside the
/// enclosing frame, and `.contentShape` extends hit-testing to the full
/// frame rather than just the glyph's drawn bounds.
struct IconButton: View {
    let icon: Image
    let action: () -> Void

    init(_ icon: Image, action: @escaping () -> Void) {
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            icon
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
    }
}
