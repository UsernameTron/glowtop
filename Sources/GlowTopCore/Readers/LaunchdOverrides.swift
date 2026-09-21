import Darwin
import Foundation

/// SPEC.md §14.4's override store. `launchctl disable` never touches a job's plist — it
/// writes here instead — so §10.2's Enabled column, which used to read only the plist's
/// `Disabled` key, would start lying the moment this phase's own `Disable` action ran.
/// `LaunchdReader.read(sources:overrides:)` reads this store and lets it win.
public enum LaunchdOverrides {
    /// The note shown in the pane's footer when the store cannot be read at all -- the
    /// Enabled column still renders, from each plist's own `Disabled` key, and says so.
    public static let unreadableNote =
        "The launchd override store is unreadable; the Enabled column falls back to each plist's own Disabled key."

    /// `/var/db/com.apple.xpc.launchd/disabled.<uid>.plist` -- world-readable, a flat
    /// `label -> Bool` dictionary where `true` means disabled (§14.4). `storeURL` is injected
    /// by tests; production passes `nil` and gets the real path for `uid`.
    public static func read(uid: uid_t = getuid(), storeURL: URL? = nil) -> (overrides: [String: Bool], note: String?) {
        let url = storeURL ?? URL(fileURLWithPath: "/var/db/com.apple.xpc.launchd/disabled.\(uid).plist")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? PropertyListDecoder().decode([String: Bool].self, from: data)
        else {
            return ([:], unreadableNote)
        }
        return (decoded, nil)
    }
}
