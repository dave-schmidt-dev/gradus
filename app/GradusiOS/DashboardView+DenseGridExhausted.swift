import GradusKit
import SwiftUI
import UIKit

/// The "Exhausted" compact-cell section of the dense grid, split out of
/// `DashboardView+DenseGrid.swift` (T3.3 gate: file/type length).
extension DashboardContent {
    /// `viewModel.providers` already arrives in `rankedPartition` order with
    /// exhausted last, so filtering here preserves both the split and the
    /// order within each half — it does not re-derive either.
    var exhaustedProviders: [ProviderStatus] {
        viewModel.providers.filter(\.isDepleted)
    }

    /// Sizes cells from the actual reset-label demand at the active Dynamic
    /// Type size. The timestamp is the exhausted cell's purpose, so an explicit
    /// solver count must never create a cell that truncates it mid-string.
    private func exhaustedColumns(metrics: DensityMetrics, contentWidth: CGFloat) -> [GridItem] {
        let columns = maxColumns(
            containerWidth: contentWidth,
            scaledFixedColumnWidth: exhaustedResetLabelWidth(for: metrics.rung),
            cardPadding: metrics.cardPadding,
            cardGap: metrics.exhaustedGap,
            minimumBarWidth: 0
        )
        return Array(
            repeating: GridItem(.flexible(), spacing: metrics.exhaustedGap, alignment: .top),
            count: columns
        )
    }

    func exhaustedSection(metrics: DensityMetrics, contentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: metrics.exhaustedGap) {
            Text("Exhausted")
                .font(metrics.exhaustedHeaderFont)
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("exhausted-section-header")
            LazyVGrid(
                columns: exhaustedColumns(metrics: metrics, contentWidth: contentWidth),
                alignment: .leading,
                spacing: metrics.exhaustedGap
            ) {
                ForEach(exhaustedProviders, id: \.providerName) { provider in
                    exhaustedCell(provider, metrics: metrics)
                }
            }
        }
    }

    private func exhaustedResetLabelWidth(for density: DashboardDensity) -> CGFloat {
        let style: UIFont.TextStyle = switch density {
        case .compact: .caption1
        case .standard: .footnote
        case .large: .subheadline
        }
        let font = UIFont.preferredFont(forTextStyle: style, compatibleWith: dynamicTypeTraits)
        return ("resets Aug 12, 7:46 PM" as NSString).size(withAttributes: [.font: font]).width
    }

    private var dynamicTypeTraits: UITraitCollection {
        let category: UIContentSizeCategory = switch dynamicTypeSize {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
        return UITraitCollection(preferredContentSizeCategory: category)
    }

    /// Still tappable through to the detail view: compact is about how much
    /// the row costs on screen, not about withholding the full breakdown from
    /// anyone who wants it.
    private func exhaustedCell(_ provider: ProviderStatus, metrics: DensityMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.exhaustedLineGap) {
            Text(provider.providerDisplayName)
                .font(metrics.exhaustedTitleFont)
                // At accessibility sizes, a one-column iPhone can no longer
                // fit a full provider name on one line. Let the cell grow
                // rather than replace part of the name with an ellipsis.
                .fixedSize(horizontal: false, vertical: true)
            Text(CrossSurfaceParity.exhaustedResetLabel(provider.windows, now: now) ?? "reset unknown")
                .font(metrics.exhaustedResetFont)
                .foregroundStyle(.secondary)
                // The solver prevents a second cramped column. A full reset
                // timestamp can still exceed a narrow phone at AX4/AX5, so it
                // wraps instead of truncating mid-timestamp.
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: metrics.exhaustedRowHeight, alignment: .leading)
        .padding(.horizontal, metrics.cardPadding)
        .padding(.vertical, metrics.exhaustedGap)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: metrics.exhaustedCornerRadius))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedProviderName = provider.providerName
        }
        .accessibilityIdentifier("exhausted-provider-\(provider.providerName)")
    }
}
