import Foundation
import GradusKit

/// Reads and watches `.state/snapshot-v2.json`, decoding through
/// `GradusKit.SnapshotPayload`. The Python writer (`write_snapshot`) writes
/// atomically via a temp file + `os.replace` — the original inode this
/// watcher opened is deleted out from under it on every write, so a plain
/// `DispatchSourceFileSystemObject` on `.write` alone silently stops
/// receiving events after the first external replace. This watcher
/// re-opens the path on `.delete`/`.rename` to follow the new inode.
public actor SnapshotWatcher {
    private let path: URL
    private let onUpdate: @Sendable (SnapshotPayload) -> Void
    private var source: DispatchSourceFileSystemObject?

    public init(path: URL, onUpdate: @escaping @Sendable (SnapshotPayload) -> Void) {
        self.path = path
        self.onUpdate = onUpdate
    }

    public func start() {
        readAndEmit()
        watch()
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    private func watch() {
        let fd = open(path.path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist yet (e.g. launchd hasn't run once). Retry
            // shortly rather than giving up on the watcher permanently.
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.watch()
            }
            return
        }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .global(qos: .utility))
        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = newSource.data
            Task {
                await self.readAndEmit()
                if flags.contains(.delete) || flags.contains(.rename) {
                    // The watched inode is gone (atomic replace). Re-open
                    // the path to follow the new file.
                    await self.rewatch()
                }
            }
        }
        newSource.setCancelHandler { close(fd) }
        newSource.resume()
        source = newSource
    }

    private func rewatch() {
        source?.cancel()
        source = nil
        watch()
    }

    private func readAndEmit() {
        guard let data = try? Data(contentsOf: path) else { return }
        guard let payload = try? JSONDecoder().decode(SnapshotPayload.self, from: data) else {
            // Malformed/partial read (rare race with the writer's fsync) —
            // the next write event will retry. Never crash on bad JSON.
            return
        }
        onUpdate(payload)
    }
}
