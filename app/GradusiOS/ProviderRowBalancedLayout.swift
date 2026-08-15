import SwiftUI

/// A row-major, row-balanced layout for the provider cards.
///
/// `LazyVGrid` keeps every card in a row at the height of that row's tallest
/// card, but its implicit sizing leaves the shorter card background ragged.
/// This layout makes that contract explicit: it measures each row, assigns
/// every card in the row the measured maximum height, and advances only after
/// the complete row. That preserves true left-to-right/top-to-bottom reading
/// order while removing the ragged below-card edge.
struct ProviderRowBalancedLayout: Layout {
    let columns: Int
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    private var resolvedColumns: Int {
        max(1, columns)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 0
        let columnWidth = widthForColumn(containerWidth: width)
        let rowHeights = rowHeights(subviews: subviews, columnWidth: columnWidth)
        let totalHeight = rowHeights.reduce(0) { partial, rowHeight in
            partial + rowHeight + (partial == 0 ? 0 : verticalSpacing)
        }
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let columnWidth = widthForColumn(containerWidth: bounds.width)
        let heights = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
        }
        let frames = Self.frames(
            cardHeights: heights,
            columns: resolvedColumns,
            cardWidth: columnWidth,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing
        )
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    /// Production's row measurement is exposed to tests so the regression
    /// check cannot drift into a duplicate arithmetic model.
    static func rowHeights(cardHeights: [CGFloat], columns: Int) -> [CGFloat] {
        let count = max(1, columns)
        // A compact iPhone is one column: preserve each card's measured
        // content height rather than turning the layout into a fixed-height
        // stack. Multi-column iPad rows are the only case that needs the
        // tallest-card rule.
        guard count > 1 else { return cardHeights }
        return stride(from: 0, to: cardHeights.count, by: count).map { start in
            cardHeights[start ..< min(start + count, cardHeights.count)].max() ?? 0
        }
    }

    /// The production frame model used by the semantic/render parity test.
    static func frames(
        cardHeights: [CGFloat],
        columns: Int,
        cardWidth: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat
    ) -> [CGRect] {
        let count = max(1, columns)
        let rows = rowHeights(cardHeights: cardHeights, columns: count)
        var result: [CGRect] = []
        var rowOrigin: CGFloat = 0
        for (row, rowHeight) in rows.enumerated() {
            let firstIndex = row * count
            let lastIndex = min(firstIndex + count, cardHeights.count)
            for index in firstIndex ..< lastIndex {
                let column = index - firstIndex
                result.append(CGRect(
                    x: CGFloat(column) * (cardWidth + horizontalSpacing),
                    y: rowOrigin,
                    width: cardWidth,
                    height: rowHeight
                ))
            }
            rowOrigin += rowHeight + verticalSpacing
        }
        return result
    }

    private func widthForColumn(containerWidth: CGFloat) -> CGFloat {
        max(
            0,
            (containerWidth - CGFloat(resolvedColumns - 1) * horizontalSpacing)
                / CGFloat(resolvedColumns)
        )
    }

    private func rowHeights(subviews: Subviews, columnWidth: CGFloat) -> [CGFloat] {
        Self.rowHeights(
            cardHeights: subviews.map {
                $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            },
            columns: resolvedColumns
        )
    }
}
