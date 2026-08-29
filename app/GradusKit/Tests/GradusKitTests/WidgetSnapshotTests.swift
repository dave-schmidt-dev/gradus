import Foundation
@testable import GradusKit
import Testing

private func makeTempDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-widget-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private let referenceDate = Date(timeIntervalSince1970: 1_785_000_000)

private func makeSampleSnapshot(
    schemaVersion: Int = WidgetSnapshot.currentSchemaVersion,
    phoneSyncDate: Date = referenceDate,
    providerName: String = "codex",
    providerDisplayName: String = "Codex",
    status: WidgetProviderStatus = .ok,
    selectedWindow: WidgetWindowSnapshot? = WidgetWindowSnapshot(
        id: "weekly",
        label: "Weekly",
        percentLeft: 42.0,
        signalLevel: .yellow,
        resetDate: referenceDate.addingTimeInterval(3600)
    )
) -> WidgetSnapshot {
    WidgetSnapshot(
        schemaVersion: schemaVersion,
        phoneSyncDate: phoneSyncDate,
        providerName: providerName,
        providerDisplayName: providerDisplayName,
        status: status,
        selectedWindow: selectedWindow
    )
}

struct InjectedWriteError: Error, Equatable {}

// MARK: - Round Trip & Schema Enforcement

@Test func widgetSnapshotRoundTripsCompletePayload() throws {
    let original = makeSampleSnapshot()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)

    #expect(decoded == original)
    #expect(decoded.schemaVersion == 2)
    #expect(decoded.phoneSyncDate == referenceDate)
    #expect(decoded.providerName == "codex")
    #expect(decoded.providerDisplayName == "Codex")
    #expect(decoded.status == .ok)
    #expect(decoded.selectedWindow?.id == "weekly")
    #expect(decoded.selectedWindow?.label == "Weekly")
    #expect(decoded.selectedWindow?.percentLeft == 42.0)
    #expect(decoded.selectedWindow?.signalLevel == .yellow)
    #expect(decoded.selectedWindow?.resetDate == referenceDate.addingTimeInterval(3600))
}

@Test func widgetSnapshotRoundTripsWithoutSelectedWindow() throws {
    let original = makeSampleSnapshot(selectedWindow: nil)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)

    #expect(decoded == original)
    #expect(decoded.selectedWindow == nil)
}

@Test func widgetSnapshotRejectsUnknownSchemaVersion() throws {
    let json = """
    {
        "schema_version": 3,
        "phone_sync_date": \(referenceDate.timeIntervalSinceReferenceDate),
        "provider_name": "codex",
        "provider_display_name": "Codex",
        "status": "ok"
    }
    """
    let data = try #require(json.data(using: .utf8))

    #expect(throws: WidgetSnapshotDecodeError.unsupportedSchemaVersion(3)) {
        try JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

// MARK: - Store Persistence, Replacement, and Injected Failure

@Test func freshStoreReturnsNilWhenFileIsMissing() {
    let dir = makeTempDirectory()
    let store = FileWidgetSnapshotStore(directory: dir)

    #expect(store.loadSnapshot() == nil)
}

@Test func storeReturnsNilWhenFileIsMalformed() throws {
    let dir = makeTempDirectory()
    let store = FileWidgetSnapshotStore(directory: dir)
    try Data("corrupted json payload".utf8).write(to: store.snapshotFileURL)

    #expect(store.loadSnapshot() == nil)
}

@Test func storeReturnsNilForUnknownSchemaVersion() throws {
    let dir = makeTempDirectory()
    let store = FileWidgetSnapshotStore(directory: dir)
    let invalidSchemaJSON = """
    {
        "schema_version": 99,
        "phone_sync_date": \(referenceDate.timeIntervalSinceReferenceDate),
        "provider_name": "codex",
        "provider_display_name": "Codex",
        "status": "ok"
    }
    """
    try invalidSchemaJSON.data(using: .utf8)?.write(to: store.snapshotFileURL)

    #expect(store.loadSnapshot() == nil)
}

@Test func storeSavesAndLoadsSnapshot() throws {
    let dir = makeTempDirectory()
    let store = FileWidgetSnapshotStore(directory: dir)
    let snapshot = makeSampleSnapshot(providerName: "claude", providerDisplayName: "Claude")

    try store.saveSnapshot(snapshot)
    #expect(store.loadSnapshot() == snapshot)
}

@Test func storeReplacementReadsNewlyCommittedSnapshot() throws {
    let dir = makeTempDirectory()
    let store = FileWidgetSnapshotStore(directory: dir)

    let snapshot1 = makeSampleSnapshot(providerName: "codex", providerDisplayName: "Codex")
    try store.saveSnapshot(snapshot1)
    #expect(store.loadSnapshot() == snapshot1)

    let snapshot2 = makeSampleSnapshot(providerName: "claude", providerDisplayName: "Claude")
    try store.saveSnapshot(snapshot2)
    #expect(store.loadSnapshot() == snapshot2)
}

@Test func injectedWriteFailurePreservesPriorFileBytesAndDecodedSnapshot() throws {
    let dir = makeTempDirectory()
    let store = FileWidgetSnapshotStore(directory: dir)

    let initialSnapshot = makeSampleSnapshot(providerName: "codex", providerDisplayName: "Codex")
    try store.saveSnapshot(initialSnapshot)

    let initialBytes = try Data(contentsOf: store.snapshotFileURL)
    #expect(!initialBytes.isEmpty)
    #expect(store.loadSnapshot() == initialSnapshot)

    // Create a store pointing to the exact same file URL with an injected failing writer.
    let failingStore = FileWidgetSnapshotStore(fileURL: store.snapshotFileURL) { _, _ in
        throw InjectedWriteError()
    }

    let newSnapshot = makeSampleSnapshot(providerName: "cursor", providerDisplayName: "Cursor")
    #expect(throws: InjectedWriteError.self) {
        try failingStore.saveSnapshot(newSnapshot)
    }

    // Prior bytes and loaded snapshot remain completely untouched.
    let afterBytes = try Data(contentsOf: store.snapshotFileURL)
    #expect(afterBytes == initialBytes)
    #expect(store.loadSnapshot() == initialSnapshot)
}

@Test func storeClearRemovesPersistedSnapshot() throws {
    let dir = makeTempDirectory()
    let store = FileWidgetSnapshotStore(directory: dir)
    let snapshot = makeSampleSnapshot()

    try store.saveSnapshot(snapshot)
    #expect(store.loadSnapshot() == snapshot)

    try store.clear()
    #expect(store.loadSnapshot() == nil)
}

// MARK: - Safe Schema Allowlist and Exclusion of Private / Raw Data

@Test func storedJSONContainsOnlyAllowlistedKeysAndNoPrivateData() throws {
    let snapshot = makeSampleSnapshot()
    let data = try JSONEncoder().encode(snapshot)
    let jsonObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    let allowedTopLevelKeys: Set = [
        "schema_version",
        "phone_sync_date",
        "providers"
    ]
    let actualTopLevelKeys = Set(jsonObject.keys)
    #expect(actualTopLevelKeys == allowedTopLevelKeys)

    let allowedWindowKeys: Set = [
        "id",
        "label",
        "percent_left",
        "signal_level",
        "reset_date"
    ]
    let providers = try #require(jsonObject["providers"] as? [[String: Any]])
    let providerDict = try #require(providers.first)
    let allowedProviderKeys: Set = [
        "provider_name",
        "provider_display_name",
        "status",
        "selected_window"
    ]
    #expect(Set(providerDict.keys) == allowedProviderKeys)
    let windowDict = try #require(providerDict["selected_window"] as? [String: Any])
    let actualWindowKeys = Set(windowDict.keys)
    #expect(actualWindowKeys == allowedWindowKeys)

    // Prohibited key tripwire: raw provider data, errors, identities, tokens, credentials, paths
    let prohibitedKeys = [
        "data", "windows", "windowsJSON", "dataJSON",
        "error", "errorMessage", "error_message", "debug_detail",
        "identity", "installationID", "installation_id", "account", "account_email",
        "token", "change_token", "changeToken", "changeTokenData",
        "credentials", "cookies", "sessionKey", "password", "auth",
        "sourceComputerName", "sourceUserName", "syncSource",
        "path", "filePath", "directory", "snapshotPath"
    ]

    for forbidden in prohibitedKeys {
        #expect(jsonObject[forbidden] == nil, "Top-level JSON must not contain key '\(forbidden)'")
        #expect(providerDict[forbidden] == nil, "Provider JSON must not contain key '\(forbidden)'")
        #expect(windowDict[forbidden] == nil, "Selected window JSON must not contain key '\(forbidden)'")
    }
}

// MARK: - Deterministic Valid-Window Selector

@Test func selectorPicksHighestSignalSeverity() {
    let red = ProviderWindow(id: "red_win", percentLeft: 40, resetISO: nil, windowHours: 5, paceDelta: -0.40)
    let orange = ProviderWindow(id: "orange_win", percentLeft: 50, resetISO: nil, windowHours: 5, paceDelta: -0.20)
    let yellow = ProviderWindow(id: "yellow_win", percentLeft: 70, resetISO: nil, windowHours: 5, paceDelta: -0.05)
    let green = ProviderWindow(id: "green_win", percentLeft: 80, resetISO: nil, windowHours: 5, paceDelta: 0.10)

    #expect(signalLevel(for: red) == .red)
    #expect(signalLevel(for: orange) == .orange)
    #expect(signalLevel(for: yellow) == .yellow)
    #expect(signalLevel(for: green) == .green)

    let chosen = selectWidgetWindow(from: [green, yellow, orange, red])
    #expect(chosen?.id == "red_win")

    let chosenSnapshot = selectWidgetWindowSnapshot(from: [green, yellow, orange, red])
    #expect(chosenSnapshot?.id == "red_win")
    #expect(chosenSnapshot?.signalLevel == .red)
}

@Test func selectorPrioritizesSignalSeverityOverPercentageRemaining() {
    // Green window with 5% remaining (ahead of pace) vs Orange window with 50% remaining (burning fast)
    let greenSmall = ProviderWindow(id: "green_low", percentLeft: 5, resetISO: nil, windowHours: 5, paceDelta: 0.10)
    let orangeHigh = ProviderWindow(id: "orange_high", percentLeft: 50, resetISO: nil, windowHours: 5, paceDelta: -0.20)

    #expect(signalLevel(for: greenSmall) == .green)
    #expect(signalLevel(for: orangeHigh) == .orange)

    let chosen = selectWidgetWindow(from: [greenSmall, orangeHigh])
    #expect(chosen?.id == "orange_high")
}

@Test func selectorTieBreaksOnLowestPercentLeftWhenSeverityIsEqual() {
    let red10 = ProviderWindow(id: "red_10", percentLeft: 10, resetISO: nil, windowHours: 5, paceDelta: -0.50)
    let red5 = ProviderWindow(id: "red_5", percentLeft: 5, resetISO: nil, windowHours: 5, paceDelta: -0.50)

    #expect(signalLevel(for: red10) == .red)
    #expect(signalLevel(for: red5) == .red)

    let chosen = selectWidgetWindow(from: [red10, red5])
    #expect(chosen?.id == "red_5")
}

@Test func selectorTieBreaksOnAscendingStableWindowIDWhenSeverityAndPercentEqual() {
    let winZeta = ProviderWindow(id: "zeta", percentLeft: 5, resetISO: nil, windowHours: 5, paceDelta: -0.50)
    let winAlpha = ProviderWindow(id: "alpha", percentLeft: 5, resetISO: nil, windowHours: 5, paceDelta: -0.50)

    let chosen = selectWidgetWindow(from: [winZeta, winAlpha])
    #expect(chosen?.id == "alpha")
}

@Test func selectorExcludesInvalidPercentWindows() {
    let nanWin = ProviderWindow(id: "nan_win", percentLeft: .nan, resetISO: nil, windowHours: nil, paceDelta: nil)
    let negWin = ProviderWindow(id: "neg_win", percentLeft: -5, resetISO: nil, windowHours: nil, paceDelta: nil)
    let overWin = ProviderWindow(id: "over_win", percentLeft: 120, resetISO: nil, windowHours: nil, paceDelta: nil)
    let validWin = ProviderWindow(id: "valid_win", percentLeft: 50, resetISO: nil, windowHours: 5, paceDelta: 0.10)

    let chosen = selectWidgetWindow(from: [nanWin, negWin, overWin, validWin])
    #expect(chosen?.id == "valid_win")

    let onlyInvalid = selectWidgetWindow(from: [nanWin, negWin, overWin])
    #expect(onlyInvalid == nil)
}

@Test func selectorReturnsNilForEmptyInput() {
    #expect(selectWidgetWindow(from: []) == nil)
    #expect(selectWidgetWindowSnapshot(from: []) == nil)
}

// MARK: - Window Label Normalization & Projection

@Test func normalizedWidgetWindowLabelNormalizesCanonicalIDsAndRetainsUnknown() {
    #expect(normalizedWidgetWindowLabel(for: "five_hour") == "5 Hour")
    #expect(normalizedWidgetWindowLabel(for: "weekly") == "Weekly")
    #expect(normalizedWidgetWindowLabel(for: "monthly") == "Monthly")
    #expect(normalizedWidgetWindowLabel(for: "premium") == "Monthly")
    #expect(normalizedWidgetWindowLabel(for: "ac") == "Auto")
    #expect(normalizedWidgetWindowLabel(for: "ap") == "API")
    #expect(normalizedWidgetWindowLabel(for: "cg5") == "5 Hour (CG)")
    #expect(normalizedWidgetWindowLabel(for: "cg1w") == "Weekly (CG)")
    #expect(normalizedWidgetWindowLabel(for: "cg_five_hour") == "5 Hour (CG)")
    #expect(normalizedWidgetWindowLabel(for: "cg_weekly") == "Weekly (CG)")
    #expect(normalizedWidgetWindowLabel(for: "billing_cycle") == "Monthly")
    #expect(normalizedWidgetWindowLabel(for: "custom_window_99") == "custom_window_99")
}

@Test func widgetWindowSnapshotProjectsNormalizedLabelAndResetDate() {
    let iso = "2026-08-23T21:30:00-04:00"
    let window = ProviderWindow(id: "five_hour", percentLeft: 50.0, resetISO: iso, windowHours: 5.0, paceDelta: 0.0)
    let projection = WidgetWindowSnapshot(from: window)

    #expect(projection.id == "five_hour")
    #expect(projection.label == "5 Hour")
    #expect(projection.percentLeft == 50.0)
    #expect(projection.signalLevel == .green)
    #expect(projection.resetDate != nil)
}

@Test func widgetWindowSnapshotParsesFractionalSecondResetTimestamps() {
    let fractionalZ = "2026-08-23T21:30:00.123Z"
    let windowZ = ProviderWindow(
        id: "five_hour", percentLeft: 50.0, resetISO: fractionalZ, windowHours: 5.0, paceDelta: 0.0
    )
    let projectionZ = WidgetWindowSnapshot(from: windowZ)
    #expect(projectionZ.resetDate != nil)
    #expect(projectionZ.resetDate?.timeIntervalSince1970 == 1_787_520_600.123)

    let fractionalOffset = "2026-08-23T21:30:00.500-04:00"
    let windowOffset = ProviderWindow(
        id: "five_hour", percentLeft: 50.0, resetISO: fractionalOffset, windowHours: 5.0, paceDelta: 0.0
    )
    let projectionOffset = WidgetWindowSnapshot(from: windowOffset)
    #expect(projectionOffset.resetDate != nil)
    #expect(projectionOffset.resetDate?.timeIntervalSince1970 == 1_787_535_000.5)

    let invalidISO = "not-a-valid-date"
    let windowInvalid = ProviderWindow(
        id: "five_hour", percentLeft: 50.0, resetISO: invalidISO, windowHours: 5.0, paceDelta: 0.0
    )
    let projectionInvalid = WidgetWindowSnapshot(from: windowInvalid)
    #expect(projectionInvalid.resetDate == nil)
}
