@testable import GradusiOS
import GradusKit
import SwiftUI
import Testing
import UIKit

// Card-size slider stop coverage split out of `DensityLayoutTests`
// (TASKS row 24): which column counts the slider offers at a given
// device width and Dynamic Type size.

private func feasibleStops(
    for device: DeviceContentWidth,
    dynamicTypeSize: DynamicTypeSize
) -> [Int] {
    let scaledColumns = scaledProductionColumnWidths(
        density: .compact, dynamicTypeSize: dynamicTypeSize
    )
    return feasibleColumnStops(
        containerWidth: device.width,
        scaledFixedColumnWidth: scaledColumns.total(
            showsReset: false, columnGap: DashboardDensity.compact.metrics.columnGap
        ),
        cardPadding: DashboardDensity.compact.metrics.cardPadding,
        cardGap: DashboardDensity.compact.metrics.cardGap,
        minimumBarWidth: DensityMetrics.minimumBarWidth
    )
}

@Test func feasibleSliderStopsCoverEveryDeviceWidthInLargerCardOrder() {
    for device in deviceContentWidths {
        let stops = feasibleStops(for: device, dynamicTypeSize: .large)
        let scaledColumns = scaledProductionColumnWidths(
            density: .compact, dynamicTypeSize: .large
        )
        let expectedMaximum = maxColumns(
            containerWidth: device.width,
            scaledFixedColumnWidth: scaledColumns.total(
                showsReset: false, columnGap: DashboardDensity.compact.metrics.columnGap
            ),
            cardPadding: DashboardDensity.compact.metrics.cardPadding,
            cardGap: DashboardDensity.compact.metrics.cardGap,
            minimumBarWidth: DensityMetrics.minimumBarWidth
        )

        #expect(stops == Array(1 ... expectedMaximum), Comment(rawValue: device.name))
        #expect(stops.allSatisfy { $0 >= 1 }, Comment(rawValue: device.name))
    }

    // A two-column layout is not offered when only one column clears the bar.
    #expect(
        feasibleColumnStops(
            containerWidth: 390,
            scaledFixedColumnWidth: 120,
            cardPadding: 12,
            cardGap: 12,
            minimumBarWidth: 48
        ) == [1]
    )
}

@Test func extraExtraExtraLargeOffersFewerSliderStopsOnTheSameDevice() {
    let device = deviceContentWidths[3]
    let defaultStops = feasibleStops(for: device, dynamicTypeSize: .large)
    let xxxLargeStops = feasibleStops(for: device, dynamicTypeSize: .xxxLarge)

    #expect(xxxLargeStops.count < defaultStops.count)
}

@Test func everyFeasibleSliderStopLeavesTheMinimumBarWidthAcrossTextSizes() {
    let metrics = DashboardDensity.compact.metrics

    for device in deviceContentWidths {
        for dynamicTypeSize in densityPropertyDynamicTypeSizes {
            let scaledColumns = scaledProductionColumnWidths(
                density: .compact, dynamicTypeSize: dynamicTypeSize
            )
            let fixedWidth = scaledColumns.total(
                showsReset: false, columnGap: metrics.columnGap
            )
            for columns in feasibleStops(for: device, dynamicTypeSize: dynamicTypeSize) {
                let barWidth = cardWidth(
                    containerWidth: device.width,
                    columns: columns,
                    cardGap: metrics.cardGap
                )
                    - metrics.cardPadding * 2
                    - fixedWidth
                #expect(
                    barWidth >= DensityMetrics.minimumBarWidth,
                    "\(device.name) at \(dynamicTypeSize), \(columns) columns"
                )
            }
        }
    }
}

@MainActor
@Test func autoUsesTheLargestFeasibleStopOnPhoneAndPad() throws {
    let phone = try #require(deviceContentWidths.first { !$0.isGrid })
    let pad = try #require(deviceContentWidths.first { $0.isGrid })
    let phoneStops = feasibleStops(for: phone, dynamicTypeSize: .large)
    let padStops = feasibleStops(for: pad, dynamicTypeSize: .large)

    #expect(phoneStops == [1], "iPhone has one feasible column count")
    #expect(try DashboardViewModel.cardSizeStopCount(for: #require(phoneStops.last)) == 1)
    #expect(padStops.count > phoneStops.count, "iPad exposes its wider feasible range")
    #expect(
        try DashboardViewModel.resolvedCardColumnCount(
            preference: 0, maximum: #require(phoneStops.last)
        ) == phoneStops.last!
    )
    #expect(
        try DashboardViewModel.resolvedCardColumnCount(
            preference: 0, maximum: #require(padStops.last)
        ) == padStops.last!
    )
    #expect(
        try DashboardViewModel.resolvedCardColumnCount(
            preference: 1, maximum: #require(padStops.last)
        ) == padStops.last!
    )
}

@Test func cardLayoutSolverKeepsBarsAboveTheFloorWhenPackingMultipleColumns() {
    struct ColumnPackingCase {
        let container: CGFloat
        let fixed: CGFloat
        let padding: CGFloat
        let gap: CGFloat
        let minimum: CGFloat
    }

    let cases: [ColumnPackingCase] = [
        ColumnPackingCase(container: 802, fixed: 246, padding: 12, gap: 12, minimum: 48),
        ColumnPackingCase(container: 1162, fixed: 246, padding: 12, gap: 16, minimum: 48),
        ColumnPackingCase(container: 1334, fixed: 246, padding: 12, gap: 20, minimum: 48)
    ]

    #expect(
        maxColumns(
            containerWidth: 10,
            scaledFixedColumnWidth: 246,
            cardPadding: 12,
            cardGap: 12,
            minimumBarWidth: 48
        ) == 1
    )

    for item in cases {
        let columns = maxColumns(
            containerWidth: item.container,
            scaledFixedColumnWidth: item.fixed,
            cardPadding: item.padding,
            cardGap: item.gap,
            minimumBarWidth: item.minimum
        )
        #expect(columns >= 1)
        if columns > 1 {
            let resolved = cardWidth(
                containerWidth: item.container, columns: columns, cardGap: item.gap
            )
            let barWidth = resolved - item.fixed - item.padding * 2
            #expect(barWidth >= item.minimum)
        }
    }
}
