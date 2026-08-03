import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// One distinct screen per `DashboardEmptyState` case (CV-5) -- each gets
/// its own copy and its own fix action, deliberately not collapsed into a
/// single generic "no data" view.
struct EmptyStateView: View {
    let state: DashboardEmptyState
    var onEnableSync: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actionButton
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var iconName: String {
        switch state {
        case .notSignedIn: return "person.crop.circle.badge.exclamationmark"
        case .syncDisabled: return "icloud.slash"
        case .waitingForFirstPublish: return "hourglass"
        }
    }

    private var title: String {
        switch state {
        case .notSignedIn: return "Not Signed In to iCloud"
        case .syncDisabled: return "iCloud Sync Is Off"
        case .waitingForFirstPublish: return "Waiting for First Publish"
        }
    }

    private var message: String {
        switch state {
        case .notSignedIn:
            return "Sign in to iCloud in Settings to see usage data from your Mac."
        case .syncDisabled:
            return "Turn on iCloud sync to see usage data from your Mac."
        case .waitingForFirstPublish:
            return "Sync is on. This fills in once your Mac publishes its first snapshot."
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .notSignedIn:
            Button("Open Settings") {
                #if canImport(UIKit)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                #endif
            }
            .buttonStyle(.borderedProminent)
        case .syncDisabled:
            Button("Enable iCloud Sync") { onEnableSync?() }
                .buttonStyle(.borderedProminent)
        case .waitingForFirstPublish:
            EmptyView()
        }
    }
}
