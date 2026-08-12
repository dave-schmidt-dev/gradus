import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// One distinct screen per `DashboardEmptyState` case (CV-5) -- each gets
/// its own copy and its own fix action, deliberately not collapsed into a
/// single generic "no data" view.
struct EmptyStateView: View {
    let state: DashboardEmptyState
    var onExploreSample: (() -> Void)?
    var onEnableSync: (() -> Void)?
    var isExploreSampleInProgress = false

    var body: some View {
        VStack(spacing: 16) {
            recoveryContent
            Button {
                onExploreSample?()
            } label: {
                HStack(spacing: 8) {
                    if isExploreSampleInProgress {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(Self.exploreSampleButtonTitle(isInProgress: isExploreSampleInProgress))
                }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("explore-sample")
            .accessibilityValue(isExploreSampleInProgress ? "In progress" : "")
            .disabled(isExploreSampleInProgress)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recoveryContent: some View {
        recoveryElements
    }

    private var recoveryElements: some View {
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
    }

    private var iconName: String {
        switch state {
        case .checkingICloud: "icloud"
        case .tryAgain: "arrow.clockwise.icloud"
        case .notSignedIn: "person.crop.circle.badge.exclamationmark"
        case .syncDisabled: "icloud.slash"
        case .restricted: "lock.icloud"
        case .awaitingConfirmation: "icloud"
        case .waitingForFirstPublish: "hourglass"
        }
    }

    private var title: String {
        switch state {
        case .checkingICloud: "Checking iCloud"
        case .tryAgain: "Try Again"
        case .notSignedIn: "Not Signed In to iCloud"
        case .syncDisabled: "iCloud Sync Is Off"
        case .restricted: "iCloud Access Restricted"
        case .awaitingConfirmation: "Continue with iCloud"
        case .waitingForFirstPublish: "Waiting for First Publish"
        }
    }

    private var message: String {
        switch state {
        case .checkingICloud:
            "Checking your iCloud account. Your cached data remains available."
        case .tryAgain:
            "Gradus could not confirm iCloud availability. Check your connection, then try again."
        case .notSignedIn:
            "Sign in to iCloud using your device's Apple Account, then return to Gradus and try again."
        case .syncDisabled:
            "Gradus needs iCloud to keep usage data available on your devices. Continue to use iCloud."
        case .restricted:
            "iCloud access is restricted for this account. If it becomes available, return to Gradus and try again."
        case .awaitingConfirmation:
            "Gradus needs iCloud to keep usage data available on your devices."
        case .waitingForFirstPublish:
            "Sync is on. This fills in once your Mac publishes its first snapshot."
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .checkingICloud:
            VStack {
                ProgressView("Checking iCloud")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("icloud-account-discovery-status")
            .accessibilityLabel("Checking iCloud")
        case .tryAgain:
            Button(Self.actionTitle(for: state)) { onEnableSync?() }
                .buttonStyle(.borderedProminent)
        case .notSignedIn:
            Button(Self.actionTitle(for: state)) { onEnableSync?() }
                .buttonStyle(.borderedProminent)
        case .syncDisabled:
            Button(Self.actionTitle(for: state)) { onEnableSync?() }
                .buttonStyle(.borderedProminent)
        case .restricted:
            Button(Self.actionTitle(for: state)) { onEnableSync?() }
                .buttonStyle(.borderedProminent)
        case .awaitingConfirmation:
            Button(Self.actionTitle(for: state)) { onEnableSync?() }
                .buttonStyle(.borderedProminent)
        case .waitingForFirstPublish:
            EmptyView()
        }
    }

    static func exploreSampleButtonTitle(isInProgress: Bool) -> String {
        isInProgress ? "Entering Sample…" : "Explore Sample"
    }

    static func actionTitle(for state: DashboardEmptyState) -> String {
        switch state {
        case .checkingICloud, .waitingForFirstPublish:
            ""
        case .tryAgain, .notSignedIn, .restricted:
            "Try Again"
        case .syncDisabled, .awaitingConfirmation:
            "Continue"
        }
    }
}
