import AppKit
import GlowTopCore
import os

/// The layering boundary §7.1 names: `Theme` holds hex strings in `GlowTopCore`, and the
/// conversion to a platform colour lives here, in the only target allowed to import AppKit.

private let log = Logger(subsystem: "com.glowtop", category: "theme")

extension Theme {
    /// A token's colour. Unknown token or malformed hex logs and returns magenta rather than
    /// crashing — §7.4's rule is that a bad colour does not stop the app launching, and a
    /// colour nothing else in the palette uses is visible in a screenshot rather than
    /// blending into the ground the way a silent black would.
    func cgColor(_ token: String, alpha: Double = 1) -> CGColor {
        guard let hex = self[token] else {
            log.error("no §7.2 token named \(token, privacy: .public)")
            return Theme.fallbackColor
        }
        return Theme.cgColor(hex: hex, alpha: alpha)
    }

    static func cgColor(hex: String, alpha: Double = 1) -> CGColor {
        guard let parsed = parseHex(hex) else {
            log.error("malformed hex \(hex, privacy: .public)")
            return fallbackColor
        }
        return CGColor(srgbRed: parsed.r, green: parsed.g, blue: parsed.b, alpha: alpha)
    }

    func color(_ token: String, alpha: Double = 1) -> Color {
        Color(nsColor: NSColor(cgColor: cgColor(token, alpha: alpha)) ?? .magenta)
    }

    static let fallbackColor = CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)

    /// `#RRGGBB`, uppercase or lowercase. Returns nil on anything else. `GlowTopCore` owns the
    /// arithmetic (`Theme.parseHexComponents`) since `Contrast.swift` and `Theme`'s own
    /// decoder need it too and neither can import AppKit (§7.1); this delegates rather than
    /// re-deriving it.
    static func parseHex(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        Theme.parseHexComponents(hex)
    }
}

import SwiftUI

extension Color {
    init(theme: Theme, _ token: String, alpha: Double = 1) {
        self = theme.color(token, alpha: alpha)
    }

    /// §4's named literals that §7.2 gives no token (`SpecLiteralColor`).
    init(hex: String, alpha: Double = 1) {
        self = Color(nsColor: NSColor(cgColor: Theme.cgColor(hex: hex, alpha: alpha)) ?? .magenta)
    }
}
