import Foundation
import GradusRefreshAgentCore

@main
struct GradusRefreshAgentApp {
    static func main() {
        guard CommandLine.arguments.count == 1,
              let executableURL = Bundle.main.executableURL
        else {
            exit(64)
        }
        exit(runInstalledRefreshAgent(
            executableURL: executableURL,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ))
    }
}
