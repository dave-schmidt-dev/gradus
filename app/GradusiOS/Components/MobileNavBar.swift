import SwiftUI

/// Minimal navigation bar (P2/T2.3): exactly one title + one trailing
/// accessory slot -- per the design system's own component rule ("one
/// trailing accessory, never a toolbar of them"). Intended to replace
/// Used inside the dashboard's populated navigation root and its settings
/// sheet; pushed provider detail uses the system navigation bar back action.
struct MobileNavBar<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

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
