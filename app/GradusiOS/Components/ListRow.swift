import SwiftUI

/// Generic settings-style row (P2/T2.2): leading icon + label + exactly
/// one trailing accessory -- per the design system's own component rule
/// ("one trailing element per row... never two controls"). Three static
/// factories each pick exactly one `Accessory` case; there is no
/// initializer that accepts two trailing controls at once.
struct ListRow: View {
    fileprivate enum Accessory {
        case toggle(Binding<Bool>)
        case chevron
        case value(String)
    }

    let icon: Image
    let label: String
    fileprivate let accessory: Accessory

    private init(icon: Image, label: String, accessory: Accessory) {
        self.icon = icon
        self.label = label
        self.accessory = accessory
    }

    /// A row with a trailing `Toggle`.
    static func toggle(icon: Image, label: String, isOn: Binding<Bool>) -> ListRow {
        ListRow(icon: icon, label: label, accessory: .toggle(isOn))
    }

    /// A row with a trailing chevron, for navigation rows.
    static func chevron(icon: Image, label: String) -> ListRow {
        ListRow(icon: icon, label: label, accessory: .chevron)
    }

    /// A row with trailing static value text, for read-only rows.
    static func value(icon: Image, label: String, value: String) -> ListRow {
        ListRow(icon: icon, label: label, accessory: .value(value))
    }

    var body: some View {
        HStack {
            icon
                .frame(width: 24)
            Text(label)
            Spacer()
            trailingAccessory
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        switch accessory {
        case .toggle(let isOn):
            Toggle(isOn: isOn) { EmptyView() }
                .labelsHidden()
        case .chevron:
            Icon.chevronRight
                .foregroundStyle(.secondary)
        case .value(let text):
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}
