import Foundation

/// SPEC.md §7.2's second column (Classic Green) and the phase-05 plan's Amber Retro table —
/// kept out of `Theme.swift` so the type and its preset data move separately.
extension Theme {
    /// §7.2's Classic Green column, in §7.2's row order. Monochrome on purpose — the
    /// phosphor-terminal preset, where everything is one green except the alarm tokens, which
    /// stay red and yellow so a thermal alarm is not rendered in the palette's own colour.
    public static let classicGreen = Theme(
        background: "#000000",
        sidebarBackground: "#050A05",
        cardBackground: "#001400",
        cardBorder: "#0A3A0A",
        gridline: "#0A2A0A",
        textPrimary: "#33FF33",
        textSecondary: "#22AA22",
        textTertiary: "#177717",
        textDisabled: "#115511",
        accentCPU: "#33FF33",
        accentMemory: "#33FF33",
        accentDisk: "#33FF33",
        accentNetwork: "#33FF33",
        accentEnergy: "#33FF33",
        accentGPU: "#33FF33",
        accentNPU: "#33FF33",
        accentThermal: "#33FF33",
        accentKernel: "#1F7A1F",
        accentClock: "#33FF33",
        warning: "#FFD60A",
        critical: "#FF453B",
        statusDegraded: "#FF9F0A",
        glowOpacity: 0.75,
        glowRadius: 8.0
    )

    /// The phase-05 plan's "Amber Retro, defined" table. Monochrome amber phosphor, same
    /// principle as Classic Green: everything one colour except the alarm tokens.
    public static let amberRetro = Theme(
        background: "#0F0B00",
        sidebarBackground: "#140E00",
        cardBackground: "#1A1200",
        cardBorder: "#3A2A00",
        gridline: "#2A1E00",
        textPrimary: "#FFB000",
        textSecondary: "#C88600",
        textTertiary: "#A87000",
        textDisabled: "#7A5200",
        accentCPU: "#FFB000",
        accentMemory: "#FFB000",
        accentDisk: "#FFB000",
        accentNetwork: "#FFB000",
        accentEnergy: "#FFB000",
        accentGPU: "#FFB000",
        accentNPU: "#FFB000",
        accentThermal: "#FFB000",
        accentKernel: "#B37A00",
        accentClock: "#FFB000",
        warning: "#FFD60A",
        critical: "#FF453B",
        statusDegraded: "#FF9F0A",
        glowOpacity: 0.70,
        glowRadius: 8.0
    )

    /// §3.4's Colors menu order and §7.4's `presetName` values — one list, so the menu and the
    /// persistence codec read the same source rather than two hand-kept ones that can drift.
    public static let allPresets: [(name: String, theme: Theme)] = [
        ("Neon", .neon),
        ("Classic Green", .classicGreen),
        ("Amber Retro", .amberRetro),
    ]
}
