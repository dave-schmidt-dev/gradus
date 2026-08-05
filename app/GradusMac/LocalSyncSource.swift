import Foundation
import GradusKit

/// The only source identity Gradus publishes: the Mac's user-visible name
/// and short local account name. No email, serial number, path, or credential
/// material is read for this display card.
enum LocalSyncSource {
    static var current: SyncSource {
        SyncSource(
            computerName: Host.current().localizedName ?? "This Mac",
            userName: NSUserName()
        )
    }
}
