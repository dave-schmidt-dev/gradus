import GradusKit
import SwiftUI

/// One-line publish provenance for the dense layout's header: `synced 2m ago ·
/// dm5mbp`.
///
/// Replaced `ConnectionInfoCard`, which was deleted on 2026-08-06 once both
/// size classes had moved to this line. That card was four stacked lines and a
/// 24pt icon at the top of the screen — real estate spent on information that
/// does not change between refreshes, which pushed provider content down and
/// was a direct cause of having to scroll. The two facts worth keeping at a
/// glance are *how stale is this* and *which machine*; the rest (user name,
/// absolute publish time) belongs in Settings.
///
/// Renders nothing at all when there is no publish timestamp *and* no source,
/// rather than showing a placeholder: an empty header is honest about a
/// dashboard that has never synced, and the empty states already explain it.
struct SyncStatusLine: View {
    let source: SyncSource?
    let publishedAt: Date?
    let now: Date

    var body: some View {
        if let renderedText {
            Text(renderedText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("sync-status-line")
        }
    }

    /// `nil` means "render nothing". The computer name is appended only when
    /// known, so a publish with no `SyncSource` still reports its age.
    var renderedText: String? {
        switch (publishedAt, source?.computerName) {
        case let (publishedAt?, computerName?):
            return "synced \(ageLabel(since: publishedAt, now: now)) ago · \(computerName)"
        case let (publishedAt?, nil):
            return "synced \(ageLabel(since: publishedAt, now: now)) ago"
        case let (nil, computerName?):
            return computerName
        case (nil, nil):
            return nil
        }
    }
}
