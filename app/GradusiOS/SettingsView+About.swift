import SwiftUI

struct AboutVersionFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

/// The "About" section of `SettingsView`: provider count and app version.
/// Split out of `SettingsView.swift` to keep that file's type body under
/// SwiftLint's length gate.
extension SettingsView {
    var aboutSection: some View {
        Section("About") {
            ListRow.value(icon: Icon.listBullet, label: "Providers", value: "\(dashboardViewModel.providers.count)")
            ListRow.value(icon: Icon.infoCircle, label: "Version", value: Self.appVersion)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: AboutVersionFramePreferenceKey.self,
                            value: geometry.frame(in: .named("settings-frame"))
                        )
                    }
                }
        }
    }

    /// `Bundle.main` in a real app run; falls back to em-dashes rather than
    /// crashing when the keys are absent (e.g. an unusual test host bundle).
    private static var appVersion: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "\u{2014}"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "\u{2014}"
        return "\(shortVersion) (\(build))"
    }
}
