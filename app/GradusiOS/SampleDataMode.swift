import Foundation
import GradusKit

enum SampleDataMode {
    static let launchArgument = "--sample-data"
    static let bannerText = "Explore Sample"
    static let bannerDetail = "Local-only sample data"
    /// Pinned to the bundled fixture's publication timestamp so reset labels
    /// and age indicators are deterministic without aging between launches.
    static let fixedNow = Date(timeIntervalSince1970: 1_786_219_200)
    static let storageDirectoryName = "Sample"
    static let preferencesSuiteName = "com.zerodelta.gradus.sample-preferences"

    enum Error: Swift.Error {
        case missingBundledData
    }

    /// The legacy launch argument remains Debug-only; the normal shipped path
    /// enters through the visible Explore Sample controls instead.
    static func isEnabled(arguments: [String], isDebugBuild: Bool) -> Bool {
        isDebugBuild && arguments.contains(launchArgument)
    }

    static func bundledProviders(bundle: Bundle = .main) throws -> [ProviderStatus] {
        guard let url = bundle.url(forResource: "SampleData", withExtension: "json") else {
            throw Error.missingBundledData
        }
        return try JSONDecoder().decode([ProviderStatus].self, from: Data(contentsOf: url))
    }

    static func storageDirectory(baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent(storageDirectoryName, isDirectory: true)
    }
}
