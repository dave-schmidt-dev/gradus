import Foundation

/// Human-readable names for schema window identifiers. The payload retains
/// stable machine identifiers while every Apple surface presents these labels.
enum ProviderWindowLabel {
    private static let labels: [String: String] = [
        "five_hour": "5 Hour",
        "weekly": "Weekly",
        "monthly": "Monthly",
        "premium": "Monthly",
        "ac": "Auto",
        "ap": "API",
        "cg5": "5 Hour (CG)",
        "cg1w": "Weekly (CG)",
        "cg_five_hour": "5 Hour (CG)",
        "cg_weekly": "Weekly (CG)",
        "billing_cycle": "Monthly"
    ]

    /// Retain an unfamiliar identifier rather than hiding data or failing.
    static func label(for id: String) -> String {
        labels[id] ?? id
    }
}
