import Foundation

/// `ProviderWindow.id` -> human-readable label mapping (P4/T4.1). Only
/// needed on a surface that renders more than one window at once and must
/// visually distinguish them -- today that's `ProviderDetailView` only (the
/// Now screen's `StatTile` still shows a single worst window, no id
/// disambiguation needed there).
///
/// Verified directly against `gradus/snapshot.py`'s `V2_WINDOW_SPECS`
/// (`snapshot.py:479-509`) -- the schema-v2 spec table that actually
/// produces the `windows[]` array published to CloudKit and decoded here
/// (`ProviderEntry.windows` flows unchanged into `ProviderStatus.windows`,
/// confirmed via `GradusMac/PublishCoordinator.swift:174,201`) -- not
/// `gradus/ui.py`'s `PROVIDER_RENDER_SPECS`/`ANTIGRAVITY_CG_WINDOWS`, a
/// separate TUI-only rendering table whose ids don't all match what's
/// actually serialized (see Cursor/CG note below).
///
/// Codex/Claude/Antigravity/OpenCode Go share `five_hour`/`weekly`(/`monthly`
/// for OpenCode Go); Copilot uses `premium`. `cg_five_hour`/`cg_weekly` are
/// included per the plan's 6-id confirmed set, but per direct `V2_WINDOW_SPECS`
/// read they don't currently appear in real `ProviderStatus.windows` data --
/// see this file's test coverage note and the implementation report for the
/// full explanation; they're harmless to keep mapped (unused key, safe
/// fallback still covers anything else) and are NOT removed here since
/// removing an entry the plan explicitly specified is a plan-scope decision,
/// not an implementation one.
///
/// Cursor/Vibe (the plan's flagged CR-8 "unverified" gap) are resolved here,
/// not left unverified: `V2_WINDOW_SPECS["Cursor"]` (`snapshot.py:438-455,
/// 479-481`) publishes two real capacity-pool ids, `"ac"` (Auto pool,
/// `auto_percent_used`) and `"ap"` (API pool, `api_percent_used`) -- NOT
/// `"billing_cycle"`, which is only `WINDOW_SPECS["Cursor"]`'s *v1* id and is
/// superseded for schema v2. Vibe has no v2 override (`V2_WINDOW_SPECS` only
/// overrides `"Cursor"` and adds the synthetic `"Antigravity (Claude)"`
/// entry), so it keeps `WINDOW_SPECS["Vibe"]`'s id unchanged: `"billing_cycle"`.
enum ProviderWindowLabel {
    private static let labels: [String: String] = [
        // Shared schema-v2 windows.
        "five_hour": "5 Hour",
        "weekly": "Weekly",
        "monthly": "Monthly",
        "premium": "Premium",
        // Cursor's schema-v2 capacity pools.
        "ac": "Auto",
        "ap": "API",
        // Antigravity's Claude+GPT alert windows. Keep longer aliases for
        // older payloads while matching the current data contract.
        "cg5": "5 Hour (CG)",
        "cg1w": "Weekly (CG)",
        "cg_five_hour": "5 Hour (CG)",
        "cg_weekly": "Weekly (CG)",
        // Vibe's billing window remains present in the v1-compatible model.
        "billing_cycle": "Billing Cycle",
    ]

    /// Falls back to the raw id string for anything outside the map above,
    /// rather than crashing or rendering blank (CR-8's required safe
    /// fallback).
    static func label(for id: String) -> String {
        labels[id] ?? id
    }
}
