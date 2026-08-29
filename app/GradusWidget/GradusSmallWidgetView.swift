import GradusKit
import SwiftUI
import WidgetKit

public struct GradusWidgetView: View {
    private let entry: GradusWidgetEntry
    @Environment(\.widgetFamily) private var family

    public init(entry: GradusWidgetEntry) {
        self.entry = entry
    }

    public var body: some View {
        switch family {
        case .systemMedium:
            GradusMediumWidgetView(entry: entry)
        default:
            GradusSmallWidgetView(entry: entry)
        }
    }
}

public struct GradusSmallWidgetView: View {
    static let railHeight: CGFloat = 12
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
                .frame(width: 86, height: Self.railHeight)
            RoundedRectangle(cornerRadius: 3)
                .fill(.secondary.opacity(0.16))
                .frame(height: Self.railHeight)
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
        .frame(height: Self.railHeight)
        .accessibilityHidden(true)
    }
}

public struct GradusMediumWidgetView: View {
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
            ForEach(0 ..< WidgetSnapshot.maximumProviderCount, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 3)
                    .fill(.secondary.opacity(0.18))
                    .frame(height: 24)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gradus usage loading")
    }

    private func message(title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)")
    }

    private func current(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Gradus")
                    .font(.headline)
                Spacer()
                syncAgeText(snapshot.phoneSyncDate)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshot.providers.prefix(WidgetSnapshot.maximumProviderCount), id: \.providerName) { provider in
                providerRow(provider)
            }
        }
    }

    private func providerRow(_ provider: WidgetProviderSnapshot) -> some View {
        let window = provider.selectedWindow
        let color = window.map { Color(signalLevel: $0.signalLevel) } ?? .secondary
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(provider.providerDisplayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let window {
                    Text(window.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(window.map { WidgetFormatting.percent($0.percentLeft) } ?? "n/a")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(color)
            }
            usageRail(percentLeft: window?.percentLeft, color: color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetFormatting.accessibilityLabel(
            provider: provider,
            locale: locale,
            timeZone: timeZone,
            calendar: calendar
        ))
    }

    @ViewBuilder
    private func syncAgeText(_ phoneSyncDate: Date) -> some View {
        if let syncAgeOverride {
            Text(syncAgeOverride)
        } else {
            Text("synced \(phoneSyncDate, style: .relative) ago")
        }
    }

    private func usageRail(percentLeft: Double?, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(
                        width: geometry.size.width * max(0, min(1, (percentLeft ?? 0) / 100))
                    )
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
