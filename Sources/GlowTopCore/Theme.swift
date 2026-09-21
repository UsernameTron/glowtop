import Foundation
import os

private let log = Logger(subsystem: "com.glowtop", category: "theme")

/// SPEC.md §7.2's token list.
///
/// Colours are hex strings, not `NSColor`: §7.1 puts the token table in `GlowTopCore` and the
/// conversion to a platform colour in `GlowTopApp`, so this type stays in a target that has
/// no AppKit and is exercised by `swift test` with no window.
///
/// `neon` lives here; §7.4's other presets are in `ThemePresets.swift`, its persistence rules in
/// `ThemeStorage.swift`, and the live editor (§7.3) in `GlowTopApp`'s `ThemeStore` and Colors pane.
public struct Theme: Codable, Sendable, Equatable {
    // Surfaces
    public let background: String
    public let sidebarBackground: String
    public let cardBackground: String
    public let cardBorder: String
    public let gridline: String

    // Text
    public let textPrimary: String
    public let textSecondary: String
    public let textTertiary: String
    public let textDisabled: String

    // Accents
    public let accentCPU: String
    public let accentMemory: String
    public let accentDisk: String
    public let accentNetwork: String
    public let accentEnergy: String
    public let accentGPU: String
    public let accentNPU: String
    public let accentThermal: String
    public let accentKernel: String
    public let accentClock: String

    // States
    public let warning: String
    public let critical: String
    /// §4.7's third health colour (3+ providers unavailable). Added phase-05: previously read
    /// through `accentThermal`, which produced the right pixels and the wrong model — editing
    /// the Thermals accent silently repainted the status bar. Identical to `accentThermal`'s
    /// value in every shipped preset; a token of its own so the two can diverge.
    public let statusDegraded: String

    /// Glow strength 0-1 and blur radius in points (§7.2's last two rows). Numbers, not hex —
    /// they are baked into the meter texture (§6.5), not applied per frame.
    public let glowOpacity: Double
    public let glowRadius: Double

    public init(
        background: String, sidebarBackground: String, cardBackground: String,
        cardBorder: String, gridline: String, textPrimary: String, textSecondary: String,
        textTertiary: String, textDisabled: String, accentCPU: String, accentMemory: String,
        accentDisk: String, accentNetwork: String, accentEnergy: String, accentGPU: String,
        accentNPU: String, accentThermal: String, accentKernel: String, accentClock: String,
        warning: String, critical: String, statusDegraded: String,
        glowOpacity: Double, glowRadius: Double
    ) {
        self.background = background
        self.sidebarBackground = sidebarBackground
        self.cardBackground = cardBackground
        self.cardBorder = cardBorder
        self.gridline = gridline
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.textDisabled = textDisabled
        self.accentCPU = accentCPU
        self.accentMemory = accentMemory
        self.accentDisk = accentDisk
        self.accentNetwork = accentNetwork
        self.accentEnergy = accentEnergy
        self.accentGPU = accentGPU
        self.accentNPU = accentNPU
        self.accentThermal = accentThermal
        self.accentKernel = accentKernel
        self.accentClock = accentClock
        self.warning = warning
        self.critical = critical
        self.statusDegraded = statusDegraded
        self.glowOpacity = glowOpacity
        self.glowRadius = glowRadius
    }

    private enum CodingKeys: String, CodingKey {
        case background, sidebarBackground, cardBackground, cardBorder, gridline,
             textPrimary, textSecondary, textTertiary, textDisabled,
             accentCPU, accentMemory, accentDisk, accentNetwork, accentEnergy,
             accentGPU, accentNPU, accentThermal, accentKernel, accentClock,
             warning, critical, statusDegraded, glowOpacity, glowRadius
    }

    /// §7.4's lenient rules, hand-written because the synthesized decoder throws on a missing
    /// key: a token missing from a stored custom theme takes Neon's value for that token
    /// (never the whole theme — this is what let `statusDegraded` land in this same phase
    /// without breaking every saved custom theme), and a malformed hex string does the same,
    /// logged rather than thrown. `encode(to:)` stays synthesized — only decoding is lenient.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let neon = Theme.neon

        // `try?` over an already-`Optional`-returning call flattens (SE-0230): a thrown
        // type-mismatch and an absent key both land in the `else` branch below, and both mean
        // the same thing here — fall back to Neon's value for this one token.
        func hex(_ key: CodingKeys, _ fallback: String) -> String {
            guard let raw = try? container.decodeIfPresent(String.self, forKey: key)
            else { return fallback }
            guard Theme.isValidHex(raw) else {
                log.error("malformed hex \(raw, privacy: .public) for token \(key.rawValue, privacy: .public) — using Neon's value")
                return fallback
            }
            return raw
        }
        func number(_ key: CodingKeys, _ fallback: Double) -> Double {
            (try? container.decodeIfPresent(Double.self, forKey: key)) ?? fallback
        }

        background = hex(.background, neon.background)
        sidebarBackground = hex(.sidebarBackground, neon.sidebarBackground)
        cardBackground = hex(.cardBackground, neon.cardBackground)
        cardBorder = hex(.cardBorder, neon.cardBorder)
        gridline = hex(.gridline, neon.gridline)
        textPrimary = hex(.textPrimary, neon.textPrimary)
        textSecondary = hex(.textSecondary, neon.textSecondary)
        textTertiary = hex(.textTertiary, neon.textTertiary)
        textDisabled = hex(.textDisabled, neon.textDisabled)
        accentCPU = hex(.accentCPU, neon.accentCPU)
        accentMemory = hex(.accentMemory, neon.accentMemory)
        accentDisk = hex(.accentDisk, neon.accentDisk)
        accentNetwork = hex(.accentNetwork, neon.accentNetwork)
        accentEnergy = hex(.accentEnergy, neon.accentEnergy)
        accentGPU = hex(.accentGPU, neon.accentGPU)
        accentNPU = hex(.accentNPU, neon.accentNPU)
        accentThermal = hex(.accentThermal, neon.accentThermal)
        accentKernel = hex(.accentKernel, neon.accentKernel)
        accentClock = hex(.accentClock, neon.accentClock)
        warning = hex(.warning, neon.warning)
        critical = hex(.critical, neon.critical)
        statusDegraded = hex(.statusDegraded, neon.statusDegraded)
        glowOpacity = number(.glowOpacity, neon.glowOpacity)
        glowRadius = number(.glowRadius, neon.glowRadius)
    }

    /// §7.2's Neon column, in §7.2's row order.
    public static let neon = Theme(
        background: "#0B0B0F",
        sidebarBackground: "#0E0E13",
        cardBackground: "#101017",
        cardBorder: "#1E1E28",
        gridline: "#1A1A22",
        textPrimary: "#F2F2F7",
        textSecondary: "#8A8A99",
        textTertiary: "#6E6E7E",
        textDisabled: "#5A5A68",
        accentCPU: "#39FF14",
        accentMemory: "#FF2D95",
        accentDisk: "#39FF14",
        accentNetwork: "#0A84FF",
        accentEnergy: "#FFD60A",
        accentGPU: "#0A84FF",
        accentNPU: "#FF453B",
        accentThermal: "#FF9F0A",
        accentKernel: "#FF453B",
        accentClock: "#FF3B30",
        warning: "#FFD60A",
        critical: "#FF453B",
        statusDegraded: "#FF9F0A",
        glowOpacity: 0.55,
        glowRadius: 6.0
    )

    /// The 22 colour tokens by name, in §7.2's order. Used by the tests now and by §7.3's
    /// editor in phase-05, so the editor enumerates the spec's rows rather than a hand-kept
    /// second list that can drift from this type.
    public static let allTokenNames: [String] = [
        "background", "sidebarBackground", "cardBackground", "cardBorder", "gridline",
        "textPrimary", "textSecondary", "textTertiary", "textDisabled",
        "accentCPU", "accentMemory", "accentDisk", "accentNetwork", "accentEnergy",
        "accentGPU", "accentNPU", "accentThermal", "accentKernel", "accentClock",
        "warning", "critical", "statusDegraded",
    ]

    /// Every colour token's value, in `allTokenNames` order.
    public var allColorValues: [String] {
        [
            background, sidebarBackground, cardBackground, cardBorder, gridline,
            textPrimary, textSecondary, textTertiary, textDisabled,
            accentCPU, accentMemory, accentDisk, accentNetwork, accentEnergy,
            accentGPU, accentNPU, accentThermal, accentKernel, accentClock,
            warning, critical, statusDegraded,
        ]
    }

    public subscript(token: String) -> String? {
        guard let index = Theme.allTokenNames.firstIndex(of: token) else { return nil }
        return allColorValues[index]
    }

    /// `#RRGGBB` → 0-1 components, uppercase or lowercase. `nil` on anything else. The one hex
    /// parser `GlowTopCore` owns; `GlowTopApp`'s `Theme+NSColor.parseHex` delegates to this
    /// rather than re-deriving it, and `Contrast.swift` uses it for the same reason this
    /// decoder does — §7.1 keeps this target free of AppKit, so nothing here can return a
    /// `CGColor`, only the components one is built from.
    public static func parseHexComponents(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var body = Substring(hex)
        if body.hasPrefix("#") { body = body.dropFirst() }
        guard body.count == 6, let value = UInt32(body, radix: 16) else { return nil }
        return (
            r: Double((value >> 16) & 0xFF) / 255,
            g: Double((value >> 8) & 0xFF) / 255,
            b: Double(value & 0xFF) / 255
        )
    }

    public static func isValidHex(_ hex: String) -> Bool { parseHexComponents(hex) != nil }
}

/// Colours §4 names literally and §7.2 gives no token. They are call-site constants rather
/// than invented token names: a token phase-05's editor would show as a row the spec never
/// specified is worse than a constant with its section cited.
public enum SpecLiteralColor {
    /// §3.2's sidebar/detail rule. One hex digit from `cardBorder` (`#1E1E28`) and not it.
    public static let sidebarRule = "#1E1E26"
    /// §4.3.3's process Name column.
    public static let processName = "#D8D8E0"
    /// §4.3.2's per-core cluster captions.
    public static let clusterCaptionP = "#7A7A88"
    public static let clusterCaptionE = "#57575F"
    /// §4.5's memory timeline layers 3 and 4.
    public static let memoryCompressed = "#C724B1"
    public static let memoryCached = "#7A2A6E"
    /// §8.2's Processes pane: alternating row backgrounds and the selected-row fill. The
    /// selected row's 2 pt leading bar reuses `accentCPU` (§8.2 says "the CPU accent", which
    /// is a token, not a literal) rather than adding a fourth literal here.
    public static let processRowEven = "#101017"
    public static let processRowOdd = "#0D0D13"
    public static let processRowSelected = "#1C2A1C"
}
