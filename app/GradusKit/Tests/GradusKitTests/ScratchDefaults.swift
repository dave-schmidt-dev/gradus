import Foundation

/// Empties a scratch `UserDefaults` suite, and best-effort removes its file.
///
/// A sibling of the helper in `app/GradusMacTests/SnapshotTestSupport.swift`,
/// duplicated rather than shared because GradusKit is a separate package and
/// this is the only thing the two test targets would have in common.
///
/// `removePersistentDomain(forName:)` clears the domain's keys and leaves the
/// plist cfprefsd made for it. Deleting that file here is best effort and
/// nothing may depend on it -- cfprefsd owns the domain and flushes its cached
/// copy on its own schedule, so a file deleted at the end of a run can reappear
/// seconds later. The guarantee is that the domain holds no keys.
func removeScratchDefaultsSuite(_ suite: String, using defaults: UserDefaults = .standard) {
    defaults.removePersistentDomain(forName: suite)
    CFPreferencesAppSynchronize(suite as CFString)
    let fileManager = FileManager.default
    for library in fileManager.urls(for: .libraryDirectory, in: .userDomainMask) {
        let plist = library
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(suite).plist")
        try? fileManager.removeItem(at: plist)
    }
}

/// A scratch suite guaranteed to start empty, under a fixed name.
///
/// Fixed rather than UUID-derived: a UUID isolates but makes the suite
/// unnameable afterwards, so every run strands a file nothing will reuse or
/// clean up. `installationIDIsStableInAppContainerAndGeneratedOnce` had left
/// 122 `presence-id-*.plist` in `~/Library/Preferences` by 2026-08-26, each one
/// holding a real installation ID. Clearing on the way in supplies the
/// isolation the UUID was there for.
func scratchDefaults(_ suite: String) -> UserDefaults? {
    removeScratchDefaultsSuite(suite)
    return UserDefaults(suiteName: suite)
}
