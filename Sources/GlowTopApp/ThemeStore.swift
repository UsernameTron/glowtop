import AppKit
import GlowTopCore
import Observation

/// The single owner of the running theme (§7.3, §7.4's discretion-table decision: one
/// `ThemeStore`, one resolved token→`CGColor` table, one notification). Every AppKit view that
/// used to hold `private let theme = Theme.neon` reads `ThemeStore.shared.theme` (or
/// `.colors` for the per-frame path) instead — the eight sites the phase-05 plan names.
@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var theme: Theme
    private(set) var presetName: String
    private(set) var colors: ThemeColors

    /// Which preset a `"Custom"` theme is a customization *of* — `presetName` itself becomes
    /// `"Custom"` the moment a token is edited, so `resetToPreset()` needs a second name to
    /// know what to restore. Not one of §7.4's three persisted keys (the spec defines none for
    /// it), so a `"Custom"` theme loaded fresh from a previous session resets to Neon — the
    /// same "unknown → Neon" rule §7.4 already applies to a malformed preset name.
    private var basePresetName: String

    /// Posted **after** `colors` is rebuilt, never before — a listener that redraws against a
    /// half-updated store draws the old palette and never redraws (this sub-step's own
    /// recorded failure shape).
    static let didChange = Notification.Name("com.glowtop.themeDidChange")

    private var undoStack: [Theme] = []
    private static let undoStackLimit = 32

    private let defaults: UserDefaults

    /// `defaults` is injectable so a caller that must not touch the real preferences domain —
    /// gate 12's self-check, chiefly — can construct an isolated store instead of mutating
    /// `.shared`'s persisted state.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = ThemeStorage.theme(
            presetName: defaults.string(forKey: ThemeStorage.presetNameKey),
            customTokensJSON: defaults.data(forKey: ThemeStorage.customTokensKey),
            version: defaults.object(forKey: ThemeStorage.versionKey) as? Int
        )
        theme = loaded.theme
        presetName = loaded.presetName
        colors = ThemeColors(theme: loaded.theme)
        basePresetName = loaded.presetName == "Custom" ? "Neon" : loaded.presetName
    }

    func select(preset name: String) {
        guard let match = Theme.allPresets.first(where: { $0.name == name }) else { return }
        pushUndo()
        basePresetName = name
        apply(theme: match.theme, presetName: name)
        persist()
    }

    /// §7.3's per-token hex edit. Unknown token names are ignored — the editor only ever
    /// offers §7.2's 22 names, so this is a guard against a programmer error, not a user one.
    func setToken(_ name: String, hex: String) {
        guard Theme.allTokenNames.contains(name), Theme.isValidHex(hex) else { return }
        pushUndo()
        apply(theme: Self.replacing(name, with: hex, in: theme), presetName: "Custom")
        persist()
    }

    /// §7.3's two numeric fields — not a §7.2 hex token, so `setToken` doesn't cover them.
    func setGlow(opacity: Double? = nil, radius: Double? = nil) {
        guard opacity != nil || radius != nil else { return }
        pushUndo()
        let updated = Theme(
            background: theme.background, sidebarBackground: theme.sidebarBackground,
            cardBackground: theme.cardBackground, cardBorder: theme.cardBorder,
            gridline: theme.gridline, textPrimary: theme.textPrimary,
            textSecondary: theme.textSecondary, textTertiary: theme.textTertiary,
            textDisabled: theme.textDisabled, accentCPU: theme.accentCPU,
            accentMemory: theme.accentMemory, accentDisk: theme.accentDisk,
            accentNetwork: theme.accentNetwork, accentEnergy: theme.accentEnergy,
            accentGPU: theme.accentGPU, accentNPU: theme.accentNPU,
            accentThermal: theme.accentThermal, accentKernel: theme.accentKernel,
            accentClock: theme.accentClock, warning: theme.warning, critical: theme.critical,
            statusDegraded: theme.statusDegraded,
            glowOpacity: opacity ?? theme.glowOpacity, glowRadius: radius ?? theme.glowRadius
        )
        apply(theme: updated, presetName: "Custom")
        persist()
    }

    /// §7.3's `Reset to preset`: restores `basePresetName`'s shipped values (the preset a
    /// `"Custom"` theme was customized *from*, or the current preset if it wasn't customized
    /// at all) and clears the custom-tokens key.
    func resetToPreset() {
        guard let match = Theme.allPresets.first(where: { $0.name == basePresetName }) else { return }
        pushUndo()
        apply(theme: match.theme, presetName: match.name)
        defaults.removeObject(forKey: ThemeStorage.customTokensKey)
        defaults.set(match.name, forKey: ThemeStorage.presetNameKey)
        defaults.set(ThemeStorage.currentVersion, forKey: ThemeStorage.versionKey)
    }

    /// §7.3's ⌘Z: one level of history per edit, 32 deep — a struct of 22 strings and two
    /// numbers is small enough that 32 of them is not a memory decision.
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        if let match = Theme.allPresets.first(where: { $0.theme == previous }) {
            basePresetName = match.name
            apply(theme: previous, presetName: match.name)
        } else {
            apply(theme: previous, presetName: "Custom")
        }
        persist()
    }

    private func pushUndo() {
        undoStack.append(theme)
        if undoStack.count > Self.undoStackLimit { undoStack.removeFirst() }
    }

    private func apply(theme: Theme, presetName: String) {
        self.theme = theme
        self.presetName = presetName
        self.colors = ThemeColors(theme: theme)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func persist() {
        defaults.set(presetName, forKey: ThemeStorage.presetNameKey)
        defaults.set(ThemeStorage.currentVersion, forKey: ThemeStorage.versionKey)
        if presetName == "Custom" {
            if let data = try? JSONEncoder().encode(theme) {
                defaults.set(data, forKey: ThemeStorage.customTokensKey)
            }
        } else {
            defaults.removeObject(forKey: ThemeStorage.customTokensKey)
        }
    }

    /// A copy of `theme` with one §7.2 token replaced. `Theme`'s properties are all `let`, so
    /// this reconstructs through the public memberwise initializer rather than mutating in
    /// place — mechanical, and it is the one place in the app that needs it.
    private static func replacing(_ token: String, with hex: String, in theme: Theme) -> Theme {
        func value(_ name: String, _ current: String) -> String { name == token ? hex : current }
        return Theme(
            background: value("background", theme.background),
            sidebarBackground: value("sidebarBackground", theme.sidebarBackground),
            cardBackground: value("cardBackground", theme.cardBackground),
            cardBorder: value("cardBorder", theme.cardBorder),
            gridline: value("gridline", theme.gridline),
            textPrimary: value("textPrimary", theme.textPrimary),
            textSecondary: value("textSecondary", theme.textSecondary),
            textTertiary: value("textTertiary", theme.textTertiary),
            textDisabled: value("textDisabled", theme.textDisabled),
            accentCPU: value("accentCPU", theme.accentCPU),
            accentMemory: value("accentMemory", theme.accentMemory),
            accentDisk: value("accentDisk", theme.accentDisk),
            accentNetwork: value("accentNetwork", theme.accentNetwork),
            accentEnergy: value("accentEnergy", theme.accentEnergy),
            accentGPU: value("accentGPU", theme.accentGPU),
            accentNPU: value("accentNPU", theme.accentNPU),
            accentThermal: value("accentThermal", theme.accentThermal),
            accentKernel: value("accentKernel", theme.accentKernel),
            accentClock: value("accentClock", theme.accentClock),
            warning: value("warning", theme.warning),
            critical: value("critical", theme.critical),
            statusDegraded: value("statusDegraded", theme.statusDegraded),
            glowOpacity: theme.glowOpacity, glowRadius: theme.glowRadius
        )
    }
}

/// The resolved token→`CGColor` table (§7.1's split kept even here: `Theme` holds hex strings,
/// this holds the platform colour). Built once per theme change, not once per stroke.
/// Cached on a string key, rebuilt on the next theme change because a new instance replaces
/// this one wholesale (`ThemeStore.apply(theme:presetName:)`).
final class ThemeColors {
    private let theme: Theme
    private var byToken: [String: CGColor] = [:]
    private var byHex: [String: CGColor] = [:]

    init(theme: Theme) {
        self.theme = theme
    }

    /// A §7.2 token's colour, cached on `"token@alpha"`. Unknown token → magenta and a log,
    /// unchanged from `Theme.cgColor(_:alpha:)`'s existing rule (§7.4: a bad colour does not
    /// stop the app launching).
    func color(_ token: String, alpha: Double = 1) -> CGColor {
        let key = "\(token)@\(alpha)"
        if let cached = byToken[key] { return cached }
        let resolved = theme.cgColor(token, alpha: alpha)
        byToken[key] = resolved
        return resolved
    }

    /// An already-resolved hex string's colour, cached on `"hex@alpha"`. `ChartLayer` reaches
    /// this path because §4.5's two spec-literal layers
    /// (`SpecLiteralColor.memoryCompressed`/`memoryCached`) resolve to a hex string before
    /// this table ever sees them, not to a §7.2 token name.
    func color(hex: String, alpha: Double = 1) -> CGColor {
        let key = "\(hex)@\(alpha)"
        if let cached = byHex[key] { return cached }
        let resolved = Theme.cgColor(hex: hex, alpha: alpha)
        byHex[key] = resolved
        return resolved
    }
}
