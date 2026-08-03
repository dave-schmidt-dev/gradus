import SwiftUI

/// Minimal navigation bar (P2/T2.3): exactly one title + one trailing
/// accessory slot -- per the design system's own component rule ("one
/// trailing accessory, never a toolbar of them"). Intended to replace
/// `DashboardView`'s current ad hoc `.toolbar { ToolbarItem { ... } }`, but
/// wiring that in is a later phase's scope -- this is the standalone
/// component only.
struct MobileNavBar<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.title2.bold())
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
