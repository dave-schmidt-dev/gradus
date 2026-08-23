import GradusKit
import SwiftUI
import WidgetKit

public struct GradusSmallWidgetView: View {
    private let entry: GradusWidgetEntry
    private let syncAgeOverride: String?
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    public init(entry: GradusWidgetEntry) {
        self.entry = entry
        syncAgeOverride = nil
    }

    init(entry: GradusWidgetEntry, syncAgeOverride: String) {
        self.entry = entry
        self.syncAgeOverride = syncAgeOverride
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color(red: 0.09, green: 0.16, blue: 0.25))
                .frame(width: 3)
            content
                .padding(.leading, 10)
        }
        .containerBackground(.background, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        switch entry.state {
        case .placeholder:
            placeholder
        case .empty:
            message(title: "Open Gradus", detail: "Sync once to add usage here.")
        case .unavailable:
            message(title: "Usage unavailable", detail: "Open Gradus to refresh.")
        case let .current(snapshot):
            current(snapshot)
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gradus")
                .font(.headline)
            RoundedRectangle(cornerRadius: 3)
                .fill(.secondary.opacity(0.22))
                .frame(width: 86, height: 12)
            RoundedRectangle(cornerRadius: 3)
                .fill(.secondary.opacity(0.16))
                .frame(height: 6)
            Spacer(minLength: 0)
            Text("synced <1m ago")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gradus usage loading")
    }

    private func message(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(title)
                .font(.headline)
                .lineLimit(2)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)")
    }

    @ViewBuilder
    private func current(_ snapshot: WidgetSnapshot) -> some View {
        if snapshot.status == .error || snapshot.selectedWindow == nil {
            message(title: "Usage unavailable", detail: "Open Gradus to refresh.")
        } else if let window = snapshot.selectedWindow {
            let signalColor = Color(signalLevel: window.signalLevel)
            VStack(alignment: .leading, spacing: 5) {
                Text(snapshot.providerDisplayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(window.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(WidgetFormatting.percent(window.percentLeft))
                    .font(.system(.title, design: .monospaced, weight: .bold))
                    .foregroundStyle(signalColor)
                    .minimumScaleFactor(0.75)
                usageRail(percentLeft: window.percentLeft, color: signalColor)
                Spacer(minLength: 0)
                if let reset = WidgetFormatting.reset(
                    window.resetDate,
                    locale: locale,
                    timeZone: timeZone,
                    calendar: calendar
                ) {
                    Text(reset)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                syncAgeText(snapshot.phoneSyncDate)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WidgetFormatting.accessibilityLabel(
                snapshot: snapshot,
                locale: locale,
                timeZone: timeZone,
                calendar: calendar
            ))
        }
    }

    @ViewBuilder
    private func syncAgeText(_ phoneSyncDate: Date) -> some View {
        if let syncAgeOverride {
            Text(syncAgeOverride)
        } else {
            Text("synced \(phoneSyncDate, style: .relative) ago")
        }
    }

    private func usageRail(percentLeft: Double, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * max(0, min(1, percentLeft / 100)))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

private extension Color {
    init(signalLevel: SignalLevel) {
        guard let hex = signalLevel.rgbHex else {
            self = .secondary
            return
        }
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
