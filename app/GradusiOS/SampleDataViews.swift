import SwiftUI

/// The banner makes the local-only state and its reversible controls visible
/// on both iPhone and iPad, including in screenshot/test builds.
struct SampleDataBanner: View {
    /// A minimum keeps the marker legible at standard text sizes; there is no
    /// upper bound so Dynamic Type can expand the banner instead of clipping
    /// its disclosure or controls.
    static let minimumHeight: CGFloat = 60
    static let maximumHeight: CGFloat? = nil

    let onExit: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SampleDataMode.bannerText)
                    .font(.caption.weight(.semibold))
                Text(SampleDataMode.bannerDetail)
                    .font(.caption2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sample-data-banner")
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Reset", action: onReset)
                .accessibilityIdentifier("sample-data-reset")
            Button("Exit", action: onExit)
                .accessibilityIdentifier("sample-data-exit")
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: Self.minimumHeight, maxHeight: Self.maximumHeight)
        .background(.yellow)
    }
}

struct SampleDataDashboard: View {
    @ObservedObject var viewModel: DashboardViewModel
    let now: Date
    let layout: DashboardLayout?
    let density: DashboardDensity?
    let onExit: () -> Void
    let onReset: () -> Void

    init(
        viewModel: DashboardViewModel,
        now: Date = Date(),
        layout: DashboardLayout? = nil,
        density: DashboardDensity? = nil,
        onExit: @escaping () -> Void = {},
        onReset: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.now = now
        self.layout = layout
        self.density = density
        self.onExit = onExit
        self.onReset = onReset
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SampleDataBanner(onExit: onExit, onReset: onReset)
                DashboardContent(
                    viewModel: viewModel, now: now, layout: layout, density: density,
                    isSampleMode: true, onExitSample: onExit, onResetSample: onReset
                )
            }
        }
    }
}
