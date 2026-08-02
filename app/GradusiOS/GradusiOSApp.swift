import SwiftUI

@main
struct GradusiOSApp: App {
    init() {
        if CommandLine.arguments.contains("--cloudkit-spike") {
            Task { await CloudKitSpike.run() }
        }
    }

    var body: some Scene {
        WindowGroup {
            Text("Gradus")
        }
    }
}
