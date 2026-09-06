import Foundation
import GradusCredentialBridgeCore

@main
struct GradusCredentialBridgeApp {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        guard let operation = CredentialBridgeOperation(arguments: arguments) else {
            exit(CredentialBridgeExitStatus.usage.rawValue)
        }
        switch operation {
        case let .refresh(cacheDirectory):
            do {
                try CredentialBridge.refresh(cacheDirectory: cacheDirectory)
            } catch {
                // This process owns browser credentials. Its callers receive only
                // an exit status, typed by `CredentialBridgeExitStatus`.
                exit(CredentialBridgeExitStatus.forRefreshError(error).rawValue)
            }
        case .check:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(CredentialBridge.check()) else {
                exit(CredentialBridgeExitStatus.failed.rawValue)
            }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}
