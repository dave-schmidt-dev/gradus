import Foundation
import GradusCredentialBridgeCore

@main
struct GradusCredentialBridgeApp {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        guard arguments.count == 2, arguments[0] == "--cache-directory" else {
            exit(64)
        }
        do {
            try CredentialBridge.refresh(cacheDirectory: URL(fileURLWithPath: arguments[1], isDirectory: true))
        } catch {
            // This process owns browser credentials. Its callers receive only an exit status.
            exit(1)
        }
    }
}
