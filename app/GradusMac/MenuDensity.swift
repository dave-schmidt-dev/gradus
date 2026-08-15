import AppKit
import GradusKit
import SwiftUI

/// The geometry used to keep the menu's provider section readable without
/// exceeding the currently usable display area. These values intentionally
/// live with the Mac menu instead of an iOS layout helper: this is a vertical,
/// fixed-width problem, while the iOS helper solves horizontal card packing.
enum MenuVerticalBudget {
    static let minimumReferenceHeight: CGFloat = 520
    /// Use the display's actual usable height before introducing a provider
    /// scrollbar. The content is a status menu, not a fixed-height panel.
    static let maximumReferenceHeight: CGFloat = 1200
    static let fallbackReferenceHeight: CGFloat = 680
    static let verticalSafetyMargin: CGFloat = 24
    /// Menu header, dividers, sync controls, action buttons, and outer padding.
    static let fixedChromeHeight: CGFloat = MenuContentView.fixedChromeHeight
    static let columnWidth: CGFloat = MenuContentView.columnWidth

    static func referenceHeight(visibleScreenHeight: CGFloat?) -> CGFloat {
        guard let visibleScreenHeight, visibleScreenHeight.isFinite else {
            return fallbackReferenceHeight
        }
        return min(
            maximumReferenceHeight,
            max(minimumReferenceHeight, visibleScreenHeight - verticalSafetyMargin)
        )
    }

    /// `visibleFrame` excludes the Dock and menu bar. Read it as the menu is
    /// built rather than caching it: displays can be attached or rearranged
    /// while Gradus is running.
    static var runtimeReferenceHeight: CGFloat {
        referenceHeight(visibleScreenHeight: NSScreen.main?.visibleFrame.height)
    }

    static func providerViewportHeight(for referenceHeight: CGFloat) -> CGFloat {
        max(240, referenceHeight - fixedChromeHeight)
    }

    static func requiredRows(for providers: [ProviderEntry]) -> Int {
        providers.reduce(0) { partial, provider in
            // One provider heading plus every provider window. Task 9.2 turns
            // that window count into rendered rows; the budget must already
            // account for all of them so that change cannot reintroduce clipping.
            partial + 1 + provider.windows.count
        }
    }

    static func resolve(
        providers: [ProviderEntry],
        dynamicTypeSize: DynamicTypeSize,
        referenceHeight: CGFloat
    ) -> MenuDensityResolution {
        let rung = MenuDensityRung.standard
        let rows = requiredRows(for: providers)
        let height = estimatedProviderHeight(for: providers, density: rung, dynamicTypeSize: dynamicTypeSize)
            + fixedChromeHeight
        return MenuDensityResolution(
            rung: rung,
            didFit: height <= referenceHeight,
            requiredRows: rows,
            intrinsicHeight: height,
            referenceHeight: referenceHeight
        )
    }

    /// Mirrors the single-column menu layout below. Every bucket has persistent
    /// reset and pace metadata, regardless of its severity color.
    private static func estimatedProviderHeight(
        for providers: [ProviderEntry],
        density: MenuDensityRung,
        dynamicTypeSize: DynamicTypeSize
    ) -> CGFloat {
        let scale = density.dynamicTypeScale(dynamicTypeSize)
        let active = providers.filter { !$0.rankingIsDepleted }
        let exhausted = providers.filter(\.rankingIsDepleted)
        let activeHeight = columnHeight(active, density: density)
        let exhaustedHeight = exhausted.isEmpty
            ? 0
            : density.exhaustionHeadingHeight + density.providerSpacing
            + columnHeight(exhausted, density: density)
        let sectionSpacing: CGFloat = active.isEmpty || exhausted.isEmpty ? 0 : density.providerSpacing
        return (activeHeight + sectionSpacing + exhaustedHeight) * scale
    }

    private static func columnHeight(_ providers: [ProviderEntry], density: MenuDensityRung) -> CGFloat {
        let providerHeights = providers.map { providerHeight($0, density: density) }
        let spacing = CGFloat(max(0, providers.count - 1)) * density.providerSpacing
        return providerHeights.reduce(0, +) + spacing
    }

    private static func providerHeight(_ provider: ProviderEntry, density: MenuDensityRung) -> CGFloat {
        if provider.ok, provider.windows.count <= 1 {
            return density.singleWindowHeight
        }
        let windowsHeight = CGFloat(provider.windows.count) * density.windowHeight
        let errorHeight = provider.ok || ProviderRetryAccessibility.isCarriedFailure(provider)
            ? 0
            : density.metadataHeight
        return density.providerHeaderHeight + windowsHeight + errorHeight
    }
}

/// There is deliberately one presentation density. A constrained display can
/// scroll, but it must not reduce type or bars beneath usable dimensions.
enum MenuDensityRung: Equatable {
    case standard

    var rowSpacing: CGFloat {
        MenuContentView.providerRowSpacing
    }

    var barHeight: CGFloat {
        MenuContentView.providerBarHeight
    }

    var providerSpacing: CGFloat {
        MenuContentView.providerGroupSpacing
    }

    var metadataFontKind: MenuMetadataFont {
        MenuContentView.providerMetadataFont
    }

    var metadataFont: Font {
        switch metadataFontKind {
        case .caption: .caption
        }
    }

    var providerHeaderHeight: CGFloat {
        20
    }

    var singleWindowHeight: CGFloat {
        48
    }

    var windowHeight: CGFloat {
        48
    }

    var metadataHeight: CGFloat {
        20
    }

    var exhaustionHeadingHeight: CGFloat {
        20
    }

    /// Split into a small accessibility-only lookup plus a standard-size
    /// lookup so neither switch carries every `DynamicTypeSize` case at once.
    /// Behavior is unchanged: accessibility sizes resolve first, and any size
    /// this type doesn't know about yet (including a future `@unknown`
    /// case) falls through to the same 1.9 the old single switch used for
    /// `@unknown default`.
    func dynamicTypeScale(_ size: DynamicTypeSize) -> CGFloat {
        Self.accessibilityScale(size) ?? Self.standardScale(size)
    }

    private static func accessibilityScale(_ size: DynamicTypeSize) -> CGFloat? {
        switch size {
        case .accessibility1: 1.42
        case .accessibility2: 1.54
        case .accessibility3: 1.66
        case .accessibility4: 1.78
        case .accessibility5: 1.9
        default: nil
        }
    }

    private static func standardScale(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.88
        case .small: 0.94
        case .medium: 1
        case .large: 1.08
        case .xLarge: 1.16
        case .xxLarge: 1.24
        case .xxxLarge: 1.32
        // Covers any size not handled above, including a future `@unknown`
        // case -- the same fallback the original combined switch used.
        default: 1.9
        }
    }
}

enum MenuMetadataFont: Equatable {
    case caption
}

struct MenuDensityResolution: Equatable {
    let rung: MenuDensityRung
    let didFit: Bool
    let requiredRows: Int
    let intrinsicHeight: CGFloat
    let referenceHeight: CGFloat

    var scrolls: Bool {
        !didFit
    }
}
