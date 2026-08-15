@testable import GradusiOS
import GradusKit
import SwiftUI
import Testing
import UIKit

// Exhausted-section grid coverage split out of `DensityLayoutTests`:
// how many columns the spent-provider grid packs on a phone or iPad,
// and that every cell keeps room for the string it exists to show.

private let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)

/// Every iPhone width the app ships to, minus `denseSingleColumn`'s 16pt
/// horizontal padding on each side. The list spans the range rather than
/// sampling it, because what this test checks is *where the column count
/// changes*, and a boundary is only visible from both sides of it.
private let phoneContentWidths: [(name: String, content: CGFloat)] = [
    ("iPhone SE / mini (375pt)", 343),
    ("iPhone 15 (390pt)", 358),
    ("iPhone 16 (393pt)", 361),
    ("iPhone 16 Pro (402pt)", 370),
    ("iPhone 16 Plus (430pt)", 398),
    ("iPhone 16 Pro Max (440pt)", 408)
]

/// The exhausted grid on a phone is the one part of this section no snapshot
/// reaches: at every density the eight active cards push it past the bottom of a
/// 393x852 viewport, so `densityLargePhoneDark` passes without covering a pixel
/// of it. That is worth stating rather than papering over with a snapshot at a
/// height no device has — the section is real, a user scrolls to it, and what
/// can be checked cheaply is the number that decides its shape.
///
/// The count is derived from the same typeset reset-label demand that the view
/// supplies to the solver. This keeps every phone from gaining a second column
/// when Dynamic Type makes the timestamp wider.
@Test func theExhaustedGridPacksAsIntendedOnEveryPhone() {
    for textStyle in exhaustedTextStyles {
        let density = textStyle.density
        let metrics = density.metrics
        for dynamicTypeSize in densityPropertyDynamicTypeSizes {
            let resetDemand = typesetWidth(
                "resets Aug 12, 7:46 PM",
                exhaustedFont(textStyle.reset, dynamicTypeSize: dynamicTypeSize)
            )
            for phone in phoneContentWidths {
                let packed = maxColumns(
                    containerWidth: phone.content,
                    scaledFixedColumnWidth: resetDemand,
                    cardPadding: metrics.cardPadding,
                    cardGap: metrics.exhaustedGap,
                    minimumBarWidth: 0
                )
                let resolvedWidth = cardWidth(
                    containerWidth: phone.content,
                    columns: packed,
                    cardGap: metrics.exhaustedGap
                )
                let textWidth = resolvedWidth - metrics.cardPadding * 2
                let widestResetToken = widestUnbreakableTokenWidth(
                    in: "resets Aug 12, 7:46 PM", font: exhaustedFont(
                        textStyle.reset, dynamicTypeSize: dynamicTypeSize
                    )
                )
                #expect(
                    textWidth >= widestResetToken,
                    """
                    \(density.rawValue) at \(dynamicTypeSize) packs \(packed) exhausted columns on \
                    \(phone.name), leaving \(textWidth)pt for its widest unbreakable reset component \
                    (\(widestResetToken)pt). The full label may wrap at accessibility sizes but must not truncate.
                    """
                )
                if resetDemand <= textWidth {
                    #expect(textWidth >= resetDemand)
                } else {
                    #expect(packed == 1)
                }
            }
        }
    }
}

/// SwiftUI's `Font` exposes neither a point size nor line metrics, so measuring
/// what the exhausted cell has to hold means going through UIKit's equivalent
/// text style. This table is the one thing the test cannot derive: it restates
/// the style each density's `exhaustedTitleFont`/`exhaustedResetFont` names.
/// Change a font in `DashboardDensity.swift` without changing the matching row
/// here and the test keeps passing while measuring the wrong string.
private struct ExhaustedTextStyleCase {
    let density: DashboardDensity
    let title: UIFont.TextStyle
    let reset: UIFont.TextStyle
}

private let exhaustedTextStyles: [ExhaustedTextStyleCase] = [
    ExhaustedTextStyleCase(density: .compact, title: .subheadline, reset: .caption1),
    ExhaustedTextStyleCase(density: .standard, title: .callout, reset: .footnote),
    ExhaustedTextStyleCase(density: .large, title: .body, reset: .subheadline)
]

private func exhaustedFont(
    _ style: UIFont.TextStyle,
    dynamicTypeSize: DynamicTypeSize = .large
) -> UIFont {
    UIFont.preferredFont(
        forTextStyle: style,
        compatibleWith: UITraitCollection(
            preferredContentSizeCategory: uiContentSizeCategory(for: dynamicTypeSize)
        )
    )
}

private func typesetWidth(_ string: String, _ font: UIFont) -> CGFloat {
    (string as NSString).size(withAttributes: [.font: font]).width
}

/// `Text` wraps at whitespace once its full line exceeds the solver-selected
/// cell width. The width assertion therefore protects every unbreakable piece,
/// which is the condition that makes the whole timestamp and provider name
/// readable without truncation on a narrow accessibility-size phone.
private func widestUnbreakableTokenWidth(in string: String, font: UIFont) -> CGFloat {
    string
        .split(whereSeparator: \.isWhitespace)
        .map { typesetWidth(String($0), font) }
        .max() ?? 0
}

/// The exhausted cell's job is to name a spent provider and say when it comes
/// back. A full reset timestamp is more important than preserving a one-line
/// cell: when Dynamic Type makes it too wide, the text wraps and the cell grows.
///
/// Asserted against the width the cell is actually *given* at each shipping
/// device width. The solver takes the typeset reset width as its fixed demand,
/// then divides the leftover space among its explicit columns.
///
/// Both strings are measured through UIKit rather than estimated from an
/// average character width. An earlier version of this test used `22 * 0.52 *
/// pointSize`; the constant had been fitted to one shipped number, which made
/// every margin it reported unfalsifiable.
@Test func exhaustedCellsFitTheStringTheyExistToShow() {
    // The widest strings the section renders: the longest provider display name
    // in the fixture set, and a full `friendlyResetDate` with month, day, and a
    // two-digit hour.
    let longestTitle = "Antigravity (Claude)"
    let longestReset = "resets Aug 12, 7:46 PM"

    for textStyle in exhaustedTextStyles {
        let density = textStyle.density
        let metrics = density.metrics
        // Every phone and iPad width, at every supported text size. The reset
        // demand is the runtime solver input; the title is verified too because
        // both labels may wrap at accessibility sizes.
        let surfaces: [DeviceContentWidth] =
            phoneContentWidths.map { DeviceContentWidth(name: $0.name, width: $0.content, isGrid: false) }
                + deviceContentWidths.filter(\.isGrid)

        for dynamicTypeSize in densityPropertyDynamicTypeSizes {
            let titleFont = exhaustedFont(textStyle.title, dynamicTypeSize: dynamicTypeSize)
            let resetFont = exhaustedFont(textStyle.reset, dynamicTypeSize: dynamicTypeSize)
            let resetDemand = typesetWidth(longestReset, resetFont)
            let needed = max(
                widestUnbreakableTokenWidth(in: longestTitle, font: titleFont),
                widestUnbreakableTokenWidth(in: longestReset, font: resetFont)
            )

            for device in surfaces {
                let columns = maxColumns(
                    containerWidth: device.width,
                    scaledFixedColumnWidth: resetDemand,
                    cardPadding: metrics.cardPadding,
                    cardGap: metrics.exhaustedGap,
                    minimumBarWidth: 0
                )
                let cellWidth = cardWidth(
                    containerWidth: device.width, columns: columns, cardGap: metrics.exhaustedGap
                )
                let textWidth = cellWidth - metrics.cardPadding * 2
                #expect(
                    textWidth >= needed,
                    """
                    \(density.rawValue) on \(device.name) at \(dynamicTypeSize): the cell gives its text \
                    \(textWidth)pt and its widest unbreakable title/reset component needs \(needed)pt, so it \
                    truncates. The reset label remains the solver's fixed demand; a full label may wrap.
                    """
                )
            }
        }

        // This height check is intentionally pinned to `.large`: it verifies the
        // unscaled metric still binds, not what Dynamic Type does. Unlike the width
        // above, falling short here does not truncate: `minHeight` is a floor,
        // so a cell whose text is taller simply grows, as the XXXL baselines
        // show. What the assertion protects is that the metric still *binds* —
        // below this figure `exhaustedRowHeight` stops setting the row height
        // and the grid's cells size to their own content instead, which is a
        // dead number pretending to be a design choice.
        let titleFont = exhaustedFont(textStyle.title)
        let resetFont = exhaustedFont(textStyle.reset)
        let twoLines =
            titleFont.lineHeight + resetFont.lineHeight + metrics.exhaustedLineGap + metrics.exhaustedGap * 2
        #expect(
            metrics.exhaustedRowHeight >= twoLines,
            """
            \(density.rawValue): exhaustedRowHeight is \(metrics.exhaustedRowHeight)pt against \
            \(twoLines)pt of content, so the minimum no longer decides the row.
            """
        )
    }
}

/// INV-12 restated against the density axis: density changes how much room a
/// provider's windows get, never how many of them are shown. A density that
/// dropped windows would be the 1.5.0 divergence again, this time shipped as a
/// setting rather than as a size-class accident.
@MainActor
@Test func everyDensityShowsEveryWindow() {
    let threeWindows = provider(
        "opencode",
        windows: [window("five_hour", 100), window("weekly", 61), window("monthly", 7)]
    )
    for density in DashboardDensity.allCases {
        let card = ProviderDensityCard(
            provider: threeWindows, now: fixedNow, metrics: density.metrics
        )
        #expect(card.visibleWindows.count == 3, "\(density.rawValue) hid a window")
    }
}
