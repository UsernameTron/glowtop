import AppKit
import GlowTopCore
import QuartzCore

/// §4.1's grid constants and §4.2's card chrome, shared by every pane that draws cards.
///
/// Moved out of `SummaryPaneView` in phase-10 (sub-step 2.1) by mechanical move only, so the
/// Performance pane constructs the same chrome rather than copying it. `SummaryPaneView.Metrics`
/// is a typealias onto this.
enum CardMetrics {
    static let outerPadding: CGFloat = 16
    static let gap: CGFloat = 12
    static let row1Height: CGFloat = 260
    static let tileRowHeight: CGFloat = 150
    static let cardPadding: CGFloat = 12
    /// §4.10: the gap between a footer and the verdict word sharing its line.
    static let verdictGap: CGFloat = 8
    static let cornerRadius: CGFloat = 10

    /// §4.1's three row-1 cards are 22 / 45 / 33 % of the content width **after** the two
    /// gaps are removed, so cards plus gaps sum to exactly the content width.
    ///
    /// §4.3.1-4.3.3's `≈253 / 517 / 379` are the percentages of the *ungapped* width and
    /// are approximate by their own `≈`: laid out literally they come to 253 + 517 + 379
    /// + 24 = 1173 inside 1148 and clip 25 pt off the right edge of the process card.
    /// §4.1 is amended in sub-step 4.3 to say which reading holds.
    static func row1Widths(contentWidth: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let usable = contentWidth - gap * 2
        return (usable * 0.22, usable * 0.45, usable * 0.33)
    }

    static func tileWidth(contentWidth: CGFloat) -> CGFloat {
        (contentWidth - gap * 2) / 3
    }

    /// §4.1's rows, gaps and outer padding: 16 + 260 + 3 × 150 + 3 × 12 + 16 = 778.
    /// §4.1 prints its own sum as 878 — the printed terms add to 778 — and a pane sized to
    /// the printed number carried 68 pt of slack, which bottom-left card frames put at
    /// the top. The pane is the terms; §4.1 is amended in 4.3.
    static let paneHeight: CGFloat =
        outerPadding * 2 + row1Height + 3 * tileRowHeight + 3 * gap

    /// §4.4's left axis: gridlines at 0/25/50/75/100 and their labels. The right-hand
    /// 0-110 axis is absent along with its series — §4.4 says an unavailable series takes
    /// its axis with it, because a scale beside a chart with nothing plotted against it
    /// invites the reader to map the green line onto degrees.
    static let percentGridlines: [Double] = [0, 25, 50, 75, 100]
}

/// The card-chrome and card-text routines `SummaryPaneView` used to own privately. A
/// namespace rather than free functions so the view's own `setText(_ key:…)` wrapper can keep
/// its name without overload ambiguity.
@MainActor
enum CardChrome {
    /// §4.2's chrome: background, 1 pt border, corner radius. The caller adds it to its root
    /// layer and keeps its own reference for theme changes.
    static func makeCardLayer(theme: Theme) -> CALayer {
        let chrome = CALayer()
        chrome.backgroundColor = Theme.cgColor(hex: theme.cardBackground)
        chrome.borderColor = Theme.cgColor(hex: theme.cardBorder)
        chrome.borderWidth = 1
        chrome.cornerRadius = CardMetrics.cornerRadius
        return chrome
    }

    static func makeTextLayer(_ string: String, size: CGFloat, weight: NSFont.Weight,
                              token: String, alignment: CATextLayerAlignmentMode,
                              tracking: CGFloat = 0, monospacedDigits: Bool = false,
                              theme: Theme) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = string
        let font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        layer.font = font
        layer.fontSize = size
        layer.foregroundColor = theme.cgColor(token)
        layer.alignmentMode = alignment
        layer.truncationMode = .middle
        // A standalone CATextLayer crossfades `contents` for 250 ms on every string change;
        // at 1 Hz that is a quarter of every second with two values legible at once.
        layer.actions = ["contents": NSNull()]
        return layer
    }

    /// §6.9: a `CATextLayer` per label whose string is set **only when it changes**, so text
    /// left the per-frame path for the same reason the meters did.
    static func setText(_ layer: CATextLayer?, _ value: String, token: String? = nil,
                        opacity: Float = 1, theme: Theme) {
        guard let layer else { return }
        if (layer.string as? String) != value { layer.string = value }
        if let token {
            let colour = theme.cgColor(token)
            if layer.foregroundColor != colour { layer.foregroundColor = colour }
        }
        if layer.opacity != opacity { layer.opacity = opacity }
    }

    /// §4.8 applied to one card's three text layers. `headlineToken` overrides the card's
    /// own accent for a live headline (Summary's process count is a `textTertiary` caption).
    static func applyCardText(_ card: CardModel, headline: CATextLayer?, footer: CATextLayer?,
                              unavailable: CATextLayer?, theme: Theme,
                              headlineToken: String? = nil) {
        // §4.8: warming is `···`, unavailable is `—`, stalled holds the last value at 35 %.
        let dimmed: Float = card.state == .stalled ? 0.35 : 1
        let live = card.state == .live || card.state == .stalled
        let token = !live ? "textDisabled" : (headlineToken ?? card.colorToken)
        setText(headline, card.headline, token: token, opacity: dimmed, theme: theme)
        setText(footer, card.footer, token: "textTertiary", opacity: dimmed, theme: theme)
        setText(unavailable, card.state.isUnavailable ? "Unavailable on this Mac" : "",
                token: "textDisabled", theme: theme)
    }
}
