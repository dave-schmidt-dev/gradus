import SwiftUI

@main
struct GradusMacApp: App {
    init() {
        if CommandLine.arguments.contains("--cloudkit-spike") {
            Task { await CloudKitSpike.run() }
        }
    }

    var body: some Scene {
        MenuBarExtra("Gradus", systemImage: "gauge") {
            Text("Gradus")
        }
    }
}
