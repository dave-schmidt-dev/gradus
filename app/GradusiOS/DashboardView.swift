import GradusKit
import SwiftUI

/// The consumer dashboard (T3.1/T3.3): a card per provider mirroring the
/// TUI, or one of the three distinct empty states (CV-5) when there's
/// nothing to show yet.
struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let now: Date

    init(viewModel: DashboardViewModel, now: Date = Date()) {
        self.viewModel = viewModel
        self.now = now
    }

    var body: some View {
        NavigationStack {
            Group {
                if let emptyState = viewModel.emptyState {
                    EmptyStateView(state: emptyState) {
                        viewModel.syncEnabled = true
                    }
                } else {
                    List(viewModel.providers, id: \.providerName) { provider in
                        ProviderCard(provider: provider, now: now)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Gradus")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle("iCloud Sync", isOn: $viewModel.syncEnabled)
                        .labelsHidden()
                }
            }
        }
    }
}
