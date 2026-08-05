import GradusKit
import SwiftUI

/// Compact provenance card for the Mac that most recently published the
/// dashboard. It uses neutral Zero Delta surfaces so it reads as context,
/// not as another provider status row.
struct ConnectionInfoCard: View {
    let source: SyncSource
    let publishedAt: Date?
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Icon.laptop
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Connected Mac")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(source.computerName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("User \(source.userName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let publishedAt {
                    Text("Last published \(friendlyDateLabel(publishedAt, now: now))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connected-computer-info")
    }
}
