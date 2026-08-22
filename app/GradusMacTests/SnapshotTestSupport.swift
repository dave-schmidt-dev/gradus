import Foundation
import SnapshotTesting
import Testing

private let stagedSnapshotRootEnvironmentKey = "GRADUS_SNAPSHOT_ROOT"
private let xcodeCloudEnvironmentKey = "CI_XCODE_CLOUD"
private let xcodeCloudWorkspaceEnvironmentKey = "CI_WORKSPACE_PATH"

func xcodeCloudSnapshotRoot(in environment: [String: String]) -> URL? {
    guard
        environment[xcodeCloudEnvironmentKey]?.uppercased() == "TRUE",
        let workspacePath = environment[xcodeCloudWorkspaceEnvironmentKey],
        !workspacePath.isEmpty
    else { return nil }

    return URL(fileURLWithPath: workspacePath, isDirectory: true)
        .appendingPathComponent("app/GradusMacTests/__Snapshots__", isDirectory: true)
}

private func snapshotSourceLocation(
    fileID: StaticString,
    file: StaticString,
    line: UInt,
    column: UInt
) -> SourceLocation {
    SourceLocation(
        fileID: fileID.description,
        filePath: file.description,
        line: Int(line),
        column: Int(column)
    )
}

private func stagedSnapshotRoot(
    fileID: StaticString,
    file: StaticString,
    line: UInt,
    column: UInt,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL? {
    let location = snapshotSourceLocation(fileID: fileID, file: file, line: line, column: column)
    guard let rawRoot = environment[stagedSnapshotRootEnvironmentKey]
        ?? xcodeCloudSnapshotRoot(in: environment)?.path,
        !rawRoot.isEmpty
    else {
        Issue.record(
            Comment(rawValue: "\(stagedSnapshotRootEnvironmentKey) is unset; refusing checkout snapshot access"),
            sourceLocation: location
        )
        return nil
    }

    let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        Issue.record(
            Comment(rawValue: "\(stagedSnapshotRootEnvironmentKey) is missing or not a directory"),
            sourceLocation: location
        )
        return nil
    }
    return root
}

/// Compares a Mac snapshot against the run-scoped baseline staged by the gate.
///
/// SnapshotTesting's default directory is adjacent to `file`, which is the
/// checkout under ~/Documents for this hosted test bundle. Resolve the
/// per-test-file directory under the explicit staged root instead, while
/// forwarding the caller's source location and test name unchanged so the
/// baseline filename remains identical.
func assertStagedSnapshot<Value>(
    of value: @autoclosure () throws -> Value,
    as snapshotting: Snapshotting<Value, some Any>,
    named name: String? = nil,
    record: SnapshotTestingConfiguration.Record? = nil,
    timeout: TimeInterval = 5,
    fileID: StaticString = #fileID,
    file: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    guard let root = stagedSnapshotRoot(fileID: fileID, file: file, line: line, column: column) else { return }

    let testFile = URL(fileURLWithPath: file.description).deletingPathExtension().lastPathComponent
    let snapshotDirectory = root.appendingPathComponent(testFile, isDirectory: true)
    guard let failure = try verifySnapshot(
        of: value(),
        as: snapshotting,
        named: name,
        record: record,
        snapshotDirectory: snapshotDirectory.path,
        timeout: timeout,
        fileID: fileID,
        file: file,
        testName: testName,
        line: line,
        column: column
    ) else { return }

    Issue.record(
        Comment(rawValue: failure),
        sourceLocation: snapshotSourceLocation(fileID: fileID, file: file, line: line, column: column)
    )
}
