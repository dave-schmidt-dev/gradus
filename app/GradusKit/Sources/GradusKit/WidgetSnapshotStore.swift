import Foundation

/// Read/write seam for the widget snapshot contract (INV-14).
public protocol WidgetSnapshotStore: Sendable {
    func loadSnapshot() -> WidgetSnapshot?
    func saveSnapshot(_ snapshot: WidgetSnapshot) throws
    func clear() throws
}

/// Directory-injected atomic JSON file store for `WidgetSnapshot`.
///
/// Missing files, malformed JSON, and unknown schema versions return `nil`
/// rather than throwing. Writes are performed atomically so an interrupted or
/// failed write preserves prior complete file bytes.
public final class FileWidgetSnapshotStore: WidgetSnapshotStore, @unchecked Sendable {
    public let snapshotFileURL: URL
    private let atomicWriter: @Sendable (Data, URL) throws -> Void

    public init(
        directory: URL,
        filename: String = "widget-snapshot.json",
        atomicWriter: (@Sendable (Data, URL) throws -> Void)? = nil
    ) {
        snapshotFileURL = directory.appendingPathComponent(filename)
        self.atomicWriter = atomicWriter ?? { data, url in
            try data.write(to: url, options: .atomic)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public init(
        fileURL: URL,
        atomicWriter: (@Sendable (Data, URL) throws -> Void)? = nil
    ) {
        snapshotFileURL = fileURL
        self.atomicWriter = atomicWriter ?? { data, url in
            try data.write(to: url, options: .atomic)
        }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    public func loadSnapshot() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotFileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    public func saveSnapshot(_ snapshot: WidgetSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try atomicWriter(data, snapshotFileURL)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: snapshotFileURL.path) else { return }
        try FileManager.default.removeItem(at: snapshotFileURL)
    }
}
