import Foundation
import os

private let log = Logger(subsystem: "com.glowtop", category: "theme.storage")

/// SPEC.md §7.4's persistence rules, as pure functions over already-read `UserDefaults`
/// values. The `UserDefaults` calls themselves live in `GlowTopApp`'s `ThemeStore` — these
/// rules are what they call, and they are testable without touching a defaults domain.
public enum ThemeStorage {
    public static let presetNameKey = "theme.presetName"
    public static let customTokensKey = "theme.customTokens"
    public static let versionKey = "theme.version"
    public static let currentVersion = 1

    /// §7.4's loading rules, applied in order:
    /// - a version above `currentVersion` → Neon, logged (reading a future schema as if it
    ///   were this one is how a theme file corrupts on downgrade);
    /// - a missing or unknown `presetName` → Neon;
    /// - a known preset name → that preset, `customTokensJSON` ignored (custom tokens are
    ///   written only when the name is `"Custom"`);
    /// - `"Custom"` with malformed or absent JSON → Neon, logged.
    ///
    /// A token missing from otherwise-valid Custom JSON, or one with a malformed hex, is
    /// `Theme`'s own lenient decoder's rule, not this function's — it defaults per token
    /// rather than falling the whole theme back to Neon.
    public static func theme(
        presetName: String?, customTokensJSON: Data?, version: Int?
    ) -> (theme: Theme, presetName: String) {
        if let version, version > currentVersion {
            log.error("theme.version \(version, privacy: .public) is newer than \(currentVersion, privacy: .public) — using Neon")
            return (.neon, "Neon")
        }

        guard let presetName else { return (.neon, "Neon") }

        if let preset = Theme.allPresets.first(where: { $0.name == presetName }) {
            return (preset.theme, preset.name)
        }

        guard presetName == "Custom" else {
            log.error("unknown theme.presetName \(presetName, privacy: .public) — using Neon")
            return (.neon, "Neon")
        }

        guard let data = customTokensJSON,
              let decoded = try? JSONDecoder().decode(Theme.self, from: data)
        else {
            log.error("theme.presetName is Custom but theme.customTokens is missing or malformed — using Neon")
            return (.neon, "Neon")
        }

        return (decoded, "Custom")
    }
}
