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
    private let accessibilityIdentifier: String?

    private init(
        icon: Image,
        label: String,
        accessory: Accessory,
        accessibilityIdentifier: String? = nil
    ) {
        self.icon = icon
        self.label = label
        self.accessory = accessory
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    /// A row with a trailing `Toggle`.
    ///
    /// The visual label remains hidden because the row already renders the
    /// label beside the control. Keep the label in the accessibility tree,
    /// however, and expose a stable identifier so UI tests and assistive
    /// technology do not depend on the row's position in the Settings list.
    static func toggle(
        icon: Image,
        label: String,
        isOn: Binding<Bool>,
        accessibilityIdentifier: String? = nil
    ) -> ListRow {
        ListRow(
            icon: icon,
            label: label,
            accessory: .toggle(isOn),
            accessibilityIdentifier: accessibilityIdentifier)
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
                .accessibilityLabel(label)
                .accessibilityIdentifier(
                    accessibilityIdentifier ?? accessibilityIdentifier(for: label))
        case .chevron:
            Icon.chevronRight
                .foregroundStyle(.secondary)
        case .value(let text):
            Text(text)
                .foregroundStyle(.secondary)
        }
    }

    private func accessibilityIdentifier(for label: String) -> String {
        let slug = label
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber ? String(character) : "-"
            }
            .joined()
        return "list-row-toggle-\(slug)"
    }
}
