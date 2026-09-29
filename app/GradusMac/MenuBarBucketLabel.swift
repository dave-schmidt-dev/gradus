import Foundation
import GradusKit
import SwiftUI

func parseSnapshotISOTimestamp(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

/// The device-local choice for the menu-bar item. Provider and window names
/// are the snapshot's stable identity; list position is deliberately absent.
enum MenuBarDisplaySelection: Hashable {
    case gauge
    case bucket(providerName: String, windowID: String)

    private struct StoredBucket: Codable {
        let providerName: String
        let windowID: String
    }

    var storedValue: String {
        switch self {
        case .gauge:
            return "gauge"
        case let .bucket(providerName, windowID):
            let bucket = StoredBucket(providerName: providerName, windowID: windowID)
            guard let data = try? JSONEncoder().encode(bucket) else { return "gauge" }
            return "bucket:" + data.base64EncodedString()
        }
    }

    init(storedValue: String?) {
        guard let storedValue, storedValue.hasPrefix("bucket:"),
              let data = Data(base64Encoded: String(storedValue.dropFirst("bucket:".count))),
              let bucket = try? JSONDecoder().decode(StoredBucket.self, from: data),
              !bucket.providerName.isEmpty, !bucket.windowID.isEmpty
        else {
            self = .gauge
            return
        }
        self = .bucket(providerName: bucket.providerName, windowID: bucket.windowID)
    }
}

struct MenuBarBucketChoice: Identifiable, Hashable {
    let selection: MenuBarDisplaySelection
    let title: String
    let available: Bool

    var id: MenuBarDisplaySelection {
        selection
    }
}

struct MenuBarBucketPresentation: Equatable {
    let title: String?
    let accessibilityLabel: String
}

extension PublisherViewModel {
    var menuBarBucketChoices: [MenuBarBucketChoice] {
        var choices = providers.flatMap { provider in
            provider.windows.map { window in
                MenuBarBucketChoice(
                    selection: .bucket(providerName: provider.name, windowID: window.id),
                    title: "\(provider.name) / \(ProviderWindowLabel.label(for: window.id))",
                    available: true
                )
            }
        }
        if case let .bucket(providerName, windowID) = menuBarDisplaySelection,
           !choices.contains(where: { $0.selection == menuBarDisplaySelection }) {
            choices.append(
                MenuBarBucketChoice(
                    selection: menuBarDisplaySelection,
                    title: "\(providerName) / \(ProviderWindowLabel.label(for: windowID)) (Unavailable)",
                    available: false
                )
            )
        }
        return choices
    }
}

enum MenuBarBucketPresenter {
    static let unavailableMarker = "—"
    static let staleMarker = "*"

    static func presentation(
        selection: MenuBarDisplaySelection,
        providers: [ProviderEntry],
        snapshotUpdatedAt: String?,
        now: Date = Date()
    ) -> MenuBarBucketPresentation {
        guard case let .bucket(providerName, windowID) = selection else {
            return MenuBarBucketPresentation(title: nil, accessibilityLabel: "Gradus usage gauge")
        }

        let compact = "\(compactProvider(providerName)) \(compactWindow(windowID))"
        let spoken = "\(providerName) \(ProviderWindowLabel.label(for: windowID).lowercased())"
        guard let provider = providers.first(where: { $0.name == providerName }),
              let window = provider.windows.first(where: { $0.id == windowID }),
              window.percentLeft.isFinite,
              (0 ... 100).contains(window.percentLeft),
              provider.ok || ProviderRetryAccessibility.isCarriedFailure(provider)
        else {
            return MenuBarBucketPresentation(
                title: "\(compact) \(unavailableMarker)",
                accessibilityLabel: "\(spoken), unavailable"
            )
        }

        let stale = ProviderRetryAccessibility.isCarriedFailure(provider)
            || !isFresh(snapshotUpdatedAt, now: now)
        let value = percentDisplay(window.percentLeft)
        let staleSuffix = stale ? ", stale" : ""
        return MenuBarBucketPresentation(
            title: "\(compact) \(value)\(stale ? staleMarker : "")",
            accessibilityLabel: "\(spoken), \(percentText(window.percentLeft)) percent remaining\(staleSuffix)"
        )
    }

    private static func isFresh(_ timestamp: String?, now: Date) -> Bool {
        guard let date = parseSnapshotISOTimestamp(timestamp) else { return false }
        let age = now.timeIntervalSince(date)
        return age >= 0 && age <= BackgroundAgentStatusResolver.staleAfter
    }

    private static func compactProvider(_ name: String) -> String {
        switch name {
        case "OpenCode Go": "OpenCode"
        default: name
        }
    }

    private static func compactWindow(_ id: String) -> String {
        switch id {
        case "five_hour": "5h"
        case "weekly": "W"
        case "monthly", "premium", "billing_cycle": "M"
        case "cg5", "cg_five_hour": "CG5"
        case "cg1w", "cg_weekly": "CGW"
        default: id.uppercased()
        }
    }
}

/// Observes the process-lifetime model so snapshots and preference changes
/// update the status item even while the menu window is closed.
struct MenuBarBucketLabel: View {
    @ObservedObject var viewModel: PublisherViewModel

    var body: some View {
        let presentation = MenuBarBucketPresenter.presentation(
            selection: viewModel.menuBarDisplaySelection,
            providers: viewModel.providers,
            snapshotUpdatedAt: viewModel.updatedAt
        )
        if let title = presentation.title {
            HStack(spacing: 4) {
                Image(systemName: "gauge")
                Text(title).monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityIdentifier("menu-bar-bucket-label")
        } else {
            Image(systemName: "gauge")
                .accessibilityLabel(presentation.accessibilityLabel)
                .accessibilityIdentifier("menu-bar-bucket-label")
        }
    }
}
