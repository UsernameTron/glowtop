import Foundation

/// SPEC.md §7.5's 4.5:1 accessibility check, as pure arithmetic over two hex strings — no
/// colour type needed, so this stays in `GlowTopCore` with the token table it checks (§7.1's
/// split between the token table and the platform colour it becomes).
public enum Contrast {
    /// WCAG's sRGB relative luminance: linear below the threshold, gamma-decoded above it,
    /// weighted 0.2126/0.7152/0.0722.
    private static func relativeLuminance(_ hex: String) -> Double? {
        guard let (r, g, b) = Theme.parseHexComponents(hex) else { return nil }
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// `(lighter + 0.05) / (darker + 0.05)`. `nil` if either hex fails to parse.
    public static func ratio(_ hexA: String, _ hexB: String) -> Double? {
        guard let luminanceA = relativeLuminance(hexA), let luminanceB = relativeLuminance(hexB)
        else { return nil }
        let lighter = max(luminanceA, luminanceB)
        let darker = min(luminanceA, luminanceB)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// §7.5's one named threshold. `false` on unparseable input — a check that cannot run does
    /// not silently pass.
    public static func meetsAA(_ text: String, on background: String) -> Bool {
        guard let ratio = ratio(text, background) else { return false }
        return ratio >= 4.5
    }
}
