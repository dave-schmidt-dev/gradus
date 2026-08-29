import GradusKit
import SwiftUI
import UIKit

/// The "Local Display" section of `SettingsView`: provider sort order, card
/// size (automatic or manual via the discrete slider below), and the
/// exhausted-provider visibility toggle. Split out of `SettingsView.swift`
/// to keep that file's type body under SwiftLint's length gate.
extension SettingsView {
    var localDisplaySection: some View {
        Section("Local Display") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sort providers")
                    .font(.headline)
                Picker("Sort providers", selection: $dashboardViewModel.providerSortOption) {
                    ForEach(ProviderSortOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text(
                    "Sorting, density and exhausted-provider visibility are local display choices on this device only."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            if dashboardViewModel.availableCardColumns <= 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Card size")
                        .font(.headline)
                    Text("Automatic · 1 column")
                    Text("Card size is automatic on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Card size")
                        .font(.headline)
                    Toggle("Automatic", isOn: automaticCardSizeBinding)
                        .accessibilityHint("When on, Gradus chooses the largest card layout that fits this device.")
                    HStack {
                        Text("Small")
                        Spacer()
                        Text(cardSizeLabel)
                            .foregroundStyle(cardSizeLabel == "Auto" ? .primary : .secondary)
                        Spacer()
                        Text("Large")
                    }
                    .font(.caption)
                    QuietDiscreteSlider(
                        value: Binding(
                            get: {
                                Double(min(max(dashboardViewModel.cardColumnPreference, 1), cardSizeStopCount))
                            },
                            set: { dashboardViewModel.cardColumnPreference = Int($0.rounded()) }
                        ),
                        range: 1 ... Double(cardSizeStopCount),
                        valueLabel: { value in
                            if dashboardViewModel.cardColumnPreference == 0 {
                                return "Auto"
                            }
                            return DashboardViewModel.cardSizeLabel(
                                preference: Int(value.rounded()),
                                maximumColumns: dashboardViewModel.availableCardColumns
                            )
                        },
                        isEnabled: cardSizeSliderEnabled
                    )
                    Text(
                        "Automatic is separate from the size slider. Small uses more columns; Large uses fewer. "
                            + "Every position keeps all provider windows visible."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            ListRow.toggle(
                icon: Icon.listBullet,
                label: "Show exhausted",
                isOn: $dashboardViewModel.showExhausted,
                accessibilityIdentifier: "show-exhausted-toggle"
            )
        }
    }

    private var cardSizeLabel: String {
        DashboardViewModel.cardSizeLabel(
            preference: dashboardViewModel.cardColumnPreference,
            maximumColumns: dashboardViewModel.availableCardColumns
        )
    }

    private var cardSizeStopCount: Int {
        DashboardViewModel.cardSizeStopCount(for: dashboardViewModel.availableCardColumns)
    }

    var automaticCardSizeBinding: Binding<Bool> {
        Binding(
            get: { dashboardViewModel.cardColumnPreference == 0 },
            set: { enabled in
                if enabled {
                    dashboardViewModel.cardColumnPreference = 0
                } else if dashboardViewModel.cardColumnPreference == 0 {
                    dashboardViewModel.cardColumnPreference = 1
                }
            }
        )
    }

    var cardSizeSliderEnabled: Bool {
        dashboardViewModel.availableCardColumns > 1
            && dashboardViewModel.cardColumnPreference != 0
    }

    var widgetProvidersSection: some View {
        Section("Widget") {
            Button {
                showingWidgetProviders = true
            } label: {
                ListRow.chevron(icon: Icon.listBullet, label: "Widget providers")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("widget-providers-button")
            Text("Choose which providers can appear in the small and medium widgets.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct WidgetProviderSettingsView: View {
    @ObservedObject var dashboardViewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    private var providers: [ProviderStatus] {
        dashboardViewModel.allProviders.sorted {
            if $0.providerDisplayName != $1.providerDisplayName {
                return $0.providerDisplayName.localizedStandardCompare($1.providerDisplayName) == .orderedAscending
            }
            return $0.providerName < $1.providerName
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MobileNavBar(title: "Widget Providers") {
                IconButton(Icon.close) { dismiss() }
                    .accessibilityIdentifier("widget-providers-close")
            }
            List {
                Section {
                    if providers.isEmpty {
                        Text("Sync Gradus to choose providers.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(providers, id: \.providerName) { provider in
                            ListRow.toggle(
                                icon: Icon.listBullet,
                                label: provider.providerDisplayName,
                                isOn: providerBinding(provider.providerName),
                                accessibilityIdentifier: "widget-provider-\(provider.providerName)-toggle"
                            )
                        }
                    }
                } footer: {
                    Text(
                        "Small shows the most urgent included provider; medium shows up to three. "
                            + "Dashboard visibility, alerts, and synced data are unchanged."
                    )
                }
            }
            .listStyle(.plain)
        }
    }

    private func providerBinding(_ providerName: String) -> Binding<Bool> {
        Binding(
            get: { dashboardViewModel.isProviderIncludedInWidget(providerName) },
            set: { dashboardViewModel.setProviderIncludedInWidget(providerName, included: $0) }
        )
    }
}

/// A discrete UIKit slider keeps the card-size control quiet. SwiftUI's
/// stepped Slider can opt into system tick feedback on newer iOS releases;
/// this control has no feedback generator. Its subclass also makes VoiceOver
/// increment and decrement exactly one whole stop instead of a fractional
/// UISlider adjustment that can round back to the same value.
private struct QuietDiscreteSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueLabel: (Double) -> String
    var isEnabled = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> QuietDiscreteUISlider {
        let slider = QuietDiscreteUISlider(frame: .zero)
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.addTarget(
            context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged
        )
        slider.accessibilityLabel = "Card size"
        update(slider)
        return slider
    }

    func updateUIView(_ slider: QuietDiscreteUISlider, context: Context) {
        context.coordinator.parent = self
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        update(slider)
    }

    private func update(_ slider: UISlider) {
        slider.isEnabled = isEnabled
        if isEnabled {
            slider.accessibilityTraits.remove(.notEnabled)
        } else {
            slider.accessibilityTraits.insert(.notEnabled)
        }
        slider.setValue(Float(value), animated: false)
        slider.accessibilityValue = valueLabel(value)
    }

    final class Coordinator: NSObject {
        var parent: QuietDiscreteSlider

        init(_ parent: QuietDiscreteSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ slider: UISlider) {
            let value = min(max(Double(slider.value).rounded(), parent.range.lowerBound), parent.range.upperBound)
            slider.setValue(Float(value), animated: false)
            parent.value = value
            slider.accessibilityValue = parent.valueLabel(value)
        }
    }
}

final class QuietDiscreteUISlider: UISlider {
    override func accessibilityIncrement() {
        adjustAccessibilityValue(by: 1)
    }

    override func accessibilityDecrement() {
        adjustAccessibilityValue(by: -1)
    }

    private func adjustAccessibilityValue(by delta: Float) {
        guard isEnabled else { return }
        let next = min(max(value.rounded() + delta, minimumValue), maximumValue)
        guard next != value else { return }
        setValue(next, animated: false)
        sendActions(for: .valueChanged)
    }
}
