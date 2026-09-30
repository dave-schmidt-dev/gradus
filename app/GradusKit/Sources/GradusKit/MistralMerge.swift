import Foundation

/// Mistral has two independent allowances. The monitor publishes them as two
/// entries ("Vibe" for the API allowance, "Vibe Code" for the Vibe Code one)
/// because the routing consumers veto on the minimum across an entry's windows.
/// Every Apple surface shows them as one "Mistral" card with two bars, so the
/// merge happens once, when a snapshot is decoded.
public enum MistralMerge {
    public static let mergedName = "Mistral"
    static let apiEntryName = "Vibe"
    static let codeEntryName = "Vibe Code"
    static let apiWindowID = "api_billing"
    /// The monitor's `billing_cycle` id is shared with Cursor, whose label is
    /// "Monthly"; the merged card renames it so it can be labelled "Vibe".
    static let codeWindowID = "vibe_billing"

    /// Replaces the two Mistral entries with one merged entry, in the position
    /// of whichever came first. The merged entry is `ok` when either allowance
    /// is, and carries only the windows of allowances that probed successfully.
    public static func merge(_ providers: [ProviderEntry]) -> [ProviderEntry] {
        let members = providers.filter { isMember($0.name) }
        guard !members.isEmpty else { return providers }
        let merged = mergedEntry(from: members)
        var result: [ProviderEntry] = []
        var placed = false
        for provider in providers {
            guard isMember(provider.name) else {
                result.append(provider)
                continue
            }
            if !placed {
                result.append(merged)
                placed = true
            }
        }
        return result
    }

    private static func isMember(_ name: String) -> Bool {
        name == apiEntryName || name == codeEntryName
    }

    private static func mergedEntry(from members: [ProviderEntry]) -> ProviderEntry {
        let healthy = members.filter(\.ok)
        guard !healthy.isEmpty else {
            return ProviderEntry(
                name: mergedName,
                ok: false,
                error: members.first?.error,
                windows: [],
                data: [:],
                observedAt: members.first?.observedAt
            )
        }
        var windows: [ProviderWindow] = []
        for member in healthy {
            windows.append(contentsOf: member.windows.map(renamed))
        }
        windows.sort { order($0.id) < order($1.id) }
        return ProviderEntry(
            name: mergedName,
            ok: true,
            error: nil,
            windows: windows,
            data: [:],
            observedAt: stalestObservation(healthy)
        )
    }

    private static func renamed(_ window: ProviderWindow) -> ProviderWindow {
        guard window.id == "billing_cycle" else { return window }
        return ProviderWindow(
            id: codeWindowID,
            percentLeft: window.percentLeft,
            resetISO: window.resetISO,
            windowHours: window.windowHours,
            paceDelta: window.paceDelta
        )
    }

    private static func order(_ id: String) -> Int {
        id == apiWindowID ? 0 : 1
    }

    /// The card is only as fresh as its stalest healthy allowance.
    private static func stalestObservation(_ members: [ProviderEntry]) -> String? {
        let stamps = members.compactMap(\.observedAt)
        let dated = stamps.compactMap { stamp in parse(stamp).map { (stamp, $0) } }
        if dated.count == stamps.count, let oldest = dated.min(by: { $0.1 < $1.1 }) {
            return oldest.0
        }
        return stamps.first
    }

    private static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
