@testable import GradusiOS
import GradusKit
import SwiftUI
import Testing
import UIKit

// Shared measurement fixtures for the density layout test suite
// (`DensityColumnPackingTests`, `DensitySliderStopsTests`,
// `DensityMetricsAndLabelsTests`, `DensityExhaustedGridTests`). These
// mirror production's `@ScaledMetric` declarations through UIKit's Dynamic
// Type scale table rather than a SwiftUI Dynamic Property, so the tests can
// measure the same numbers off-view. No `@Test` lives in this file.

/// A destination the gate runs, with its content width inside `denseGrid`'s
/// shared horizontal inset.
struct DeviceContentWidth {
    let name: String
    let width: CGFloat
    let isGrid: Bool
}

let deviceContentWidths: [DeviceContentWidth] = [
    DeviceContentWidth(name: "iPhone portrait", width: 393 - dashboardHorizontalInset * 2, isGrid: false),
    DeviceContentWidth(name: "iPad 11\" portrait", width: 834 - dashboardHorizontalInset * 2, isGrid: true),
    DeviceContentWidth(name: "iPad 11\" landscape", width: 1194 - dashboardHorizontalInset * 2, isGrid: true),
    DeviceContentWidth(name: "iPad 13\" landscape", width: 1366 - dashboardHorizontalInset * 2, isGrid: true)
]

let densityPropertyDynamicTypeSizes: [DynamicTypeSize] = [
    .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
    .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5
]

/// The styles here mirror the nine `@ScaledMetric` declarations in
/// `WindowRow` and `DashboardContent`. UIKit supplies the same Dynamic Type
/// scale table without reading a SwiftUI Dynamic Property off-view.
private enum ProductionScaledMetricStyle {
    case caption
    case caption2
    case footnote
    case subheadline

    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .caption: .caption1
        case .caption2: .caption2
        case .footnote: .footnote
        case .subheadline: .subheadline
        }
    }
}

func uiContentSizeCategory(for size: DynamicTypeSize) -> UIContentSizeCategory {
    accessibilityContentSizeCategory(for: size) ?? standardContentSizeCategory(for: size)
}

/// `nil` for every non-accessibility size, so the caller falls through to
/// `standardContentSizeCategory(for:)` instead of duplicating its default case.
private func accessibilityContentSizeCategory(for size: DynamicTypeSize) -> UIContentSizeCategory? {
    switch size {
    case .accessibility1: .accessibilityMedium
    case .accessibility2: .accessibilityLarge
    case .accessibility3: .accessibilityExtraLarge
    case .accessibility4: .accessibilityExtraExtraLarge
    case .accessibility5: .accessibilityExtraExtraExtraLarge
    default: nil
    }
}

private func standardContentSizeCategory(for size: DynamicTypeSize) -> UIContentSizeCategory {
    switch size {
    case .xSmall: .extraSmall
    case .small: .small
    case .medium: .medium
    case .large: .large
    case .xLarge: .extraLarge
    case .xxLarge: .extraExtraLarge
    case .xxxLarge: .extraExtraExtraLarge
    @unknown default: .large
    }
}

private func scaledProductionMetric(
    _ value: CGFloat,
    relativeTo style: ProductionScaledMetricStyle,
    dynamicTypeSize: DynamicTypeSize
) -> CGFloat {
    let traits = UITraitCollection(
        preferredContentSizeCategory: uiContentSizeCategory(for: dynamicTypeSize)
    )
    return UIFontMetrics(forTextStyle: style.uiTextStyle)
        .scaledValue(for: value, compatibleWith: traits)
}

struct ScaledFixedColumnWidths {
    let label: CGFloat
    let percent: CGFloat
    let reset: CGFloat

    func total(showsReset: Bool, columnGap: CGFloat) -> CGFloat {
        label + percent + (showsReset ? reset : 0)
            + columnGap * CGFloat(showsReset ? 3 : 2)
    }
}

private struct ColumnMetricStyles {
    let label: ProductionScaledMetricStyle
    let percent: ProductionScaledMetricStyle
    let reset: ProductionScaledMetricStyle
}

func scaledProductionColumnWidths(
    density: DashboardDensity,
    dynamicTypeSize: DynamicTypeSize
) -> ScaledFixedColumnWidths {
    let metrics = density.metrics
    let styles = switch density {
    case .compact:
        ColumnMetricStyles(label: .caption, percent: .caption, reset: .caption2)
    case .standard:
        ColumnMetricStyles(label: .footnote, percent: .footnote, reset: .caption)
    case .large:
        ColumnMetricStyles(label: .subheadline, percent: .subheadline, reset: .footnote)
    }
    return ScaledFixedColumnWidths(
        label: scaledProductionMetric(
            metrics.labelWidth, relativeTo: styles.label, dynamicTypeSize: dynamicTypeSize
        ),
        percent: scaledProductionMetric(
            metrics.percentWidth, relativeTo: styles.percent, dynamicTypeSize: dynamicTypeSize
        ),
        reset: scaledProductionMetric(
            metrics.resetWidth, relativeTo: styles.reset, dynamicTypeSize: dynamicTypeSize
        )
    )
}
