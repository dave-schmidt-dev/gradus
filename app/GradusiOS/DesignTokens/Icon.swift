import SwiftUI

/// Design-system icon tokens (P1/T1.2): a thin, semantic wrapper over
/// `Image(systemName:)` so call sites read `Icon.warning` instead of
/// stringly-typed SF Symbol names scattered across views.
enum Icon {
    static var offline: Image {
        Image(systemName: "icloud.slash")
    }

    static var syncing: Image {
        Image(systemName: "arrow.clockwise")
    }

    static var warning: Image {
        Image(systemName: "exclamationmark.triangle.fill")
    }

    static var bell: Image {
        Image(systemName: "bell")
    }

    static var settings: Image {
        Image(systemName: "gearshape")
    }

    static var refresh: Image {
        Image(systemName: "arrow.clockwise")
    }

    static var chevronLeft: Image {
        Image(systemName: "chevron.left")
    }

    static var chevronRight: Image {
        Image(systemName: "chevron.right")
    }

    static var laptop: Image {
        Image(systemName: "laptopcomputer")
    }

    static var phone: Image {
        Image(systemName: "iphone")
    }

    static var clock: Image {
        Image(systemName: "clock")
    }

    static var checkmarkCircle: Image {
        Image(systemName: "checkmark.circle")
    }

    static var listBullet: Image {
        Image(systemName: "list.bullet")
    }

    static var infoCircle: Image {
        Image(systemName: "info.circle")
    }

    static var noConnection: Image {
        Image(systemName: "wifi.slash")
    }

    static var accountWarning: Image {
        Image(systemName: "person.crop.circle.badge.exclamationmark")
    }

    /// P5/T5.3: dismiss control for the Settings sheet -- not in the
    /// original SF-Symbol/Lucide map (the map covers Phase 1-4 call sites
    /// only), added here since Settings ships as a sheet with its own close
    /// affordance.
    static var close: Image {
        Image(systemName: "xmark")
    }
}
