import CoreGraphics

/// Resolves the card width produced by a fixed column count and inter-card gap.
///
/// This is the arithmetic behind SwiftUI's adaptive column packing after the
/// count has been selected. All inputs are already scaled for the active text
/// size and density.
func cardWidth(containerWidth: CGFloat, columns: Int, cardGap: CGFloat) -> CGFloat {
    let resolvedColumns = max(1, columns)
    return (containerWidth - cardGap * CGFloat(resolvedColumns - 1))
        / CGFloat(resolvedColumns)
}

/// Selects the largest column count whose cards leave the bar's minimum width.
///
/// The fixed columns and card padding are part of each card's minimum demand.
/// A too-narrow container still resolves to one column, matching SwiftUI's
/// adaptive behavior rather than producing an invalid zero-column layout.
func maxColumns(
    containerWidth: CGFloat,
    scaledFixedColumnWidth: CGFloat,
    cardPadding: CGFloat,
    cardGap: CGFloat,
    minimumBarWidth: CGFloat
) -> Int {
    let minimumCardWidth = scaledFixedColumnWidth + cardPadding * 2 + minimumBarWidth
    let columns = floor((containerWidth + cardGap) / (minimumCardWidth + cardGap))
    return max(1, Int(columns))
}

/// Returns the column counts a size slider may offer for this card geometry.
///
/// The counts are ordered for presentation: one column is first because it
/// gives each card the most room. A position is omitted when even one column
/// cannot leave the requested bar width; `maxColumns` still retains its
/// adaptive one-column fallback for callers that must render a card.
func feasibleColumnStops(
    containerWidth: CGFloat,
    scaledFixedColumnWidth: CGFloat,
    cardPadding: CGFloat,
    cardGap: CGFloat,
    minimumBarWidth: CGFloat
) -> [Int] {
    let largestColumnCount = maxColumns(
        containerWidth: containerWidth,
        scaledFixedColumnWidth: scaledFixedColumnWidth,
        cardPadding: cardPadding,
        cardGap: cardGap,
        minimumBarWidth: minimumBarWidth
    )
    let oneColumnBarWidth = cardWidth(
        containerWidth: containerWidth,
        columns: 1,
        cardGap: cardGap
    )
        - cardPadding * 2
        - scaledFixedColumnWidth
    guard oneColumnBarWidth >= minimumBarWidth else { return [] }
    return Array(1 ... largestColumnCount)
}

/// One candidate rung's column-packing demand, richest first.
struct RungCandidate<Rung> {
    let rung: Rung
    let scaledFixedColumnWidth: CGFloat
    let cardPadding: CGFloat
    let cardGap: CGFloat
}

/// Auto's algorithm: the richest candidate that seats at least one column at
/// `minimumBarWidth`, paired with the most columns *that same candidate* can
/// seat.
///
/// The naive alternative -- fix the column count at what the leanest
/// candidate's demand allows, then ask each candidate in turn whether it fits
/// at that fixed count -- starves every richer candidate of the width it
/// would otherwise use, so it always falls through to the leanest one. That
/// also wastes vertical space: the leanest candidate has the shortest rows,
/// so packing the most columns of it leaves the fewest rows and the most
/// blank space below them. Asking each candidate for its own maximum column
/// count, richest first, is what actually uses the screen.
func richestFittingResolution<Rung>(
    containerWidth: CGFloat,
    candidates: [RungCandidate<Rung>],
    minimumBarWidth: CGFloat
) -> (rung: Rung, columns: Int)? {
    for candidate in candidates {
        let stops = feasibleColumnStops(
            containerWidth: containerWidth,
            scaledFixedColumnWidth: candidate.scaledFixedColumnWidth,
            cardPadding: candidate.cardPadding,
            cardGap: candidate.cardGap,
            minimumBarWidth: minimumBarWidth
        )
        if let columns = stops.last {
            return (candidate.rung, columns)
        }
    }
    return nil
}
