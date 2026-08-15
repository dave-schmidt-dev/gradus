import Foundation

/// The device-relative card-size slider: translating a persisted preference
/// into a column count/density rung, and reconciling that preference against
/// the maximum column count the current geometry can actually offer.
extension DashboardViewModel {
    /// Updates the Settings slider's device-relative range. A legacy explicit
    /// column count is translated once the current geometry is known;
    /// `DashboardContent` then clamps it against each live geometry pass.
    public func setAvailableCardColumns(_ maximum: Int) {
        let maximum = max(1, maximum)
        availableCardColumns = maximum
        if maximum == 1 {
            // A one-column geometry cannot honor a manual card-size choice.
            // Keep the effective preference on Automatic, but defer the
            // explicit stop so a temporarily narrow iPad restores it when
            // regular geometry returns. Phones remain one-column forever and
            // therefore never expose or apply that deferred stop.
            if let legacyColumns = pendingLegacyCardColumnPreference {
                userDefaults.set(legacyColumns, forKey: Self.pendingLegacyCardColumnPreferenceKey)
            }
            if cardColumnPreference != 0 {
                userDefaults.set(cardColumnPreference, forKey: Self.deferredCardSizePreferenceKey)
                cardColumnPreference = 0
            }
            return
        }
        if let legacyColumns = pendingLegacyCardColumnPreference {
            pendingLegacyCardColumnPreference = nil
            userDefaults.removeObject(forKey: Self.pendingLegacyCardColumnPreferenceKey)
            let clampedColumns = min(max(legacyColumns, 1), maximum)
            cardColumnPreference = max(1, maximum - clampedColumns + 1)
            return
        }
        let deferredPreference = max(
            0, userDefaults.integer(forKey: Self.deferredCardSizePreferenceKey)
        )
        guard cardColumnPreference == 0, deferredPreference > 0 else { return }
        userDefaults.removeObject(forKey: Self.deferredCardSizePreferenceKey)
        cardColumnPreference = min(max(deferredPreference, 1), maximum)
    }

    /// Resolves Auto (`0`) to the largest feasible count; explicit slider
    /// stops are clamped to the same device-relative range.
    nonisolated static func resolvedCardColumnCount(preference: Int, maximum: Int) -> Int {
        resolvedCardColumnCount(preference: preference, maximum: maximum, sizeStops: maximum)
    }

    /// Resolves the persisted slider stop to a column count. The first
    /// explicit stop is the smallest-card presentation (the maximum feasible
    /// column count); later stops remove columns toward Large. A one-column
    /// device has no explicit stops and stays on Automatic.
    nonisolated static func resolvedCardColumnCount(preference: Int, maximum: Int, sizeStops _: Int) -> Int {
        let maximum = max(1, maximum)
        guard preference != 0 else { return maximum }
        let position = min(max(preference, 1), maximum)
        return max(1, maximum - position + 1)
    }

    /// Number of positions offered by the device-relative card-size slider.
    /// A one-column device has no manual size choice: its layout is Automatic.
    nonisolated static func cardSizeStopCount(for maximumColumns: Int) -> Int {
        max(1, maximumColumns)
    }

    /// Maps an explicit slider stop from Small at the left to Large at the
    /// right. Auto (`0`) remains separate and is resolved geometrically.
    nonisolated static func resolvedCardDensity(preference: Int, sizeStops: Int) -> DashboardDensity? {
        guard preference > 0 else { return nil }
        let stops = max(1, sizeStops)
        let position = min(max(preference, 1), stops) - 1
        let index = Int((Double(position) * 2 / Double(max(1, stops - 1))).rounded())
        return DashboardDensity.allCases[min(index, DashboardDensity.allCases.count - 1)]
    }

    nonisolated static func cardSizeLabel(preference: Int, maximumColumns: Int) -> String {
        guard preference != 0, maximumColumns > 1 else { return "Auto" }
        let stops = cardSizeStopCount(for: maximumColumns)
        let density = resolvedCardDensity(preference: preference, sizeStops: stops) ?? .large
        let columns = resolvedCardColumnCount(
            preference: preference, maximum: maximumColumns, sizeStops: stops
        )
        let size = switch density {
        case .compact: "Small"
        case .standard: "Medium"
        case .large: "Large"
        }
        let suffix = columns == 1 ? "1 column" : "\(columns) columns"
        return "\(size) · \(suffix)"
    }
}
