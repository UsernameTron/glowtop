import AppKit
import GlowTopCore
import QuartzCore

/// A segmented meter, composited on the GPU. SPEC.md §6.5.
///
/// Extracted verbatim from phase-01's `CoreBarsView` and generalised over accent, geometry
/// and axis; the mechanism is unchanged and its gate-12 self-check moved with it. A meter is
/// a static picture revealed to a variable height, which is a crop, and a crop is what a
/// compositor does for free: the texture is rendered once per backing scale, the lit fraction
/// is a `contentsRect`, and the app sets two properties per meter ten times a second and does
/// nothing at all on the other fifty frames.

enum MeterAxis: Hashable {
    case vertical
    case horizontal
}

/// One meter's shape. Three instances exist in phase-03; see the table in
/// `MeterGeometry.verticalMeter` and friends.
struct MeterGeometry: Hashable {
    let segmentCount: Int
    /// Along the fill axis: §4.3.1's 3 pt segment height, §4.5's 5 pt segment width.
    let segmentLength: CGFloat
    let segmentGap: CGFloat
    /// Across the fill axis: §4.3.1's and §4.5's 22 pt.
    let thickness: CGFloat
    let cornerRadius: CGFloat
    let axis: MeterAxis

    /// §4.3.1: 40 × 3 pt with 1 pt gaps, 22 pt wide → 40×3 + 39×1 = 159 pt tall.
    static let verticalMeter = MeterGeometry(
        segmentCount: 40, segmentLength: 3, segmentGap: 1, thickness: 22,
        cornerRadius: 1, axis: .vertical
    )

    /// §4.5: 40 × 5 pt with 1.5 pt gaps, 22 pt tall → 40×5 + 39×1.5 = 258.5 pt wide.
    static let memoryMeter = MeterGeometry(
        segmentCount: 40, segmentLength: 5, segmentGap: 1.5, thickness: 22,
        cornerRadius: 1, axis: .horizontal
    )

    /// §4.3.2's per-core strip: 6 pt tall, no segment count given, so one continuous segment
    /// through the same crop mechanism. One primitive, not two.
    static func perCoreStrip(width: CGFloat) -> MeterGeometry {
        MeterGeometry(segmentCount: 1, segmentLength: width, segmentGap: 0, thickness: 6,
                      cornerRadius: 1, axis: .horizontal)
    }

    /// The meter's extent along its fill axis.
    var length: CGFloat {
        CGFloat(segmentCount) * segmentLength + CGFloat(segmentCount - 1) * segmentGap
    }

    var size: CGSize {
        axis == .vertical
            ? CGSize(width: thickness, height: length)
            : CGSize(width: length, height: thickness)
    }
}

/// Texture cache key. Keyed on the geometry as well as the accent: keyed on accent alone, the
/// memory meter is handed the CPU meter's 3 pt/1 pt geometry, which presents as a colour bug
/// and is a geometry bug.
private struct TextureKey: Hashable {
    let hex: String
    let geometry: MeterGeometry
    let lit: Bool
    let scale: CGFloat
    let glowRadius: CGFloat
}

@MainActor
final class MeterLayer {
    let unlit = CALayer()
    let lit = CALayer()

    private let geometry: MeterGeometry
    private var accentHex: String
    private var theme: Theme
    private var scale: CGFloat = 0
    private var currentState: CardState = .warming

    private static var textureCache: [TextureKey: CGImage] = [:]

    private var glowRadius: CGFloat { theme.glowRadius }
    private var paddedSize: CGSize {
        CGSize(width: geometry.size.width + glowRadius * 2,
               height: geometry.size.height + glowRadius * 2)
    }

    init(geometry: MeterGeometry, accentHex: String, theme: Theme) {
        self.geometry = geometry
        self.accentHex = accentHex
        self.theme = theme

        lit.contentsGravity = geometry.axis == .vertical ? .bottom : .left
        lit.contentsRect = Self.emptyCrop(for: geometry.axis)
        lit.isHidden = true
    }

    func addTo(_ parent: CALayer) {
        parent.addSublayer(unlit)
        parent.addSublayer(lit)
    }

    /// Places the meter. `origin` is the bottom-left of the *unlit* body; the lit layer sits
    /// `glowRadius` outside it on every side so the baked glow is not clipped.
    func layout(origin: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        unlit.frame = CGRect(origin: origin, size: geometry.size)
        lit.frame = CGRect(
            x: origin.x - glowRadius, y: origin.y - glowRadius,
            width: paddedSize.width, height: paddedSize.height
        )
        CATransaction.commit()
    }

    func updateScale(_ newScale: CGFloat) {
        guard newScale > 0, newScale != scale else { return }
        scale = newScale
        reloadTexture()
    }

    /// Re-resolves this meter's accent and glow parameters against a new theme and reloads its
    /// texture at the current scale. Called on `ThemeStore.didChange` — the shared texture
    /// cache (`invalidateTextureCache()`) must be cleared first, or this reads back the stale
    /// image under the old key's colour baked in (§7.3's live-apply rule: no relaunch).
    func updateTheme(accentHex: String, theme: Theme) {
        self.accentHex = accentHex
        self.theme = theme
        guard scale > 0 else { return }
        reloadTexture()
    }

    private func reloadTexture() {
        unlit.contentsScale = scale
        lit.contentsScale = scale
        unlit.contents = Self.texture(TextureKey(hex: accentHex, geometry: geometry, lit: false,
                                                 scale: scale, glowRadius: glowRadius),
                                      theme: theme)
        lit.contents = Self.texture(TextureKey(hex: accentHex, geometry: geometry, lit: true,
                                               scale: scale, glowRadius: glowRadius),
                                    theme: theme)
    }

    /// §4.8's three appearances. `fraction: nil` never draws a zero-height lit run, because a
    /// zero-height run is indistinguishable from a real zero.
    func set(fraction: Double?, state: CardState, over interval: Duration) {
        currentState = state

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch state {
        case .live:
            unlit.opacity = 1
            lit.opacity = 1
        case .warming:
            // Alive, no delta yet: all segments unlit at full strength.
            unlit.opacity = 1
            lit.opacity = 1
            lit.isHidden = true
        case .unavailable:
            // §4.8: unlit at 4 % where live is 8 %, so half.
            unlit.opacity = 0.5
            lit.isHidden = true
        case .stalled:
            // Hold the last crop, dimmed. Blanking destroys information; full strength lies.
            unlit.opacity = 0.35
            lit.opacity = 0.35
        }
        CATransaction.commit()

        guard state == .live, let fraction else { return }
        animate(to: fraction, over: interval)
    }

    private func animate(to value: Double, over interval: Duration) {
        let (seconds, attos) = interval.components
        let duration = Double(seconds) + Double(attos) * 1e-18

        let segments = min(max(Int((value * Double(geometry.segmentCount)).rounded()), 0),
                           geometry.segmentCount)
        // A one-segment strip (§4.3.2) is continuous, so it crops by the raw fraction rather
        // than by a rounded segment count — rounding a 1-segment meter is a two-state meter.
        let target = geometry.segmentCount == 1
            ? Self.continuousCrop(min(max(value, 0), 1), axis: geometry.axis,
                                  geometry: geometry, glowRadius: glowRadius)
            : Self.contentsRect(litSegments: segments, geometry: geometry, glowRadius: glowRadius)

        let from = lit.presentation()?.contentsRect ?? lit.contentsRect

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lit.isHidden = geometry.segmentCount == 1 ? value <= 0 : segments == 0
        lit.contentsRect = target
        CATransaction.commit()

        guard !lit.isHidden, duration > 0 else { return }

        let animation = CABasicAnimation(keyPath: "contentsRect")
        animation.fromValue = from
        animation.toValue = target
        animation.duration = duration
        // §6.6 rule 3: linear. Easing a measurement introduces overshoot that reads as a
        // value the machine never had.
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        lit.add(animation, forKey: "lit")
    }

    // MARK: - The crop

    static func emptyCrop(for axis: MeterAxis) -> CGRect {
        axis == .vertical
            ? CGRect(x: 0, y: 1, width: 1, height: 0)
            : CGRect(x: 0, y: 0, width: 0, height: 1)
    }

    /// The crop that reveals `litSegments` from the bottom (vertical) or the leading edge
    /// (horizontal) of the texture.
    ///
    /// `contentsRect` is in the unit space of the contents image, whose origin is its
    /// **top-left**. Revealing the bottom fraction `v` therefore means starting at `1 - v`;
    /// revealing the leading fraction `v` means starting at `0`. The horizontal case is a
    /// second platform convention, not arithmetic derived from the first — transliterating
    /// the vertical case gives `x: 1 - v`, which fills the memory meter and all fourteen
    /// per-core strips **from the right**, is identical at 50 %, and is symmetric enough
    /// elsewhere to survive a glance. §13.7.12 exists for exactly this, one axis over.
    static func contentsRect(
        litSegments: Int, geometry: MeterGeometry, glowRadius: CGFloat
    ) -> CGRect {
        guard litSegments > 0 else { return emptyCrop(for: geometry.axis) }

        let litLength = CGFloat(litSegments) * geometry.segmentLength
            + CGFloat(litSegments - 1) * geometry.segmentGap
        let textureLength = geometry.length + glowRadius * 2
        let visible = min(litLength + glowRadius * 2, textureLength)
        let fraction = visible / textureLength

        return geometry.axis == .vertical
            ? CGRect(x: 0, y: 1 - fraction, width: 1, height: fraction)
            : CGRect(x: 0, y: 0, width: fraction, height: 1)
    }

    /// A continuous (one-segment) meter's crop. §4.3.2's strip.
    static func continuousCrop(
        _ value: Double, axis: MeterAxis, geometry: MeterGeometry, glowRadius: CGFloat
    ) -> CGRect {
        guard value > 0 else { return emptyCrop(for: axis) }
        let textureLength = geometry.length + glowRadius * 2
        let visible = min(geometry.length * value + glowRadius * 2, textureLength)
        let fraction = visible / textureLength
        return axis == .vertical
            ? CGRect(x: 0, y: 1 - fraction, width: 1, height: fraction)
            : CGRect(x: 0, y: 0, width: fraction, height: 1)
    }

    // MARK: - Texture

    private static func texture(_ key: TextureKey, theme: Theme) -> CGImage? {
        if let cached = textureCache[key] { return cached }

        let geometry = key.geometry
        let accent = Theme.cgColor(hex: key.hex)
        // The lit texture carries glowRadius of padding on every side so the glow around the
        // lit run is not clipped; the unlit one has no glow and needs none.
        let padding = key.lit ? key.glowRadius : 0
        let size = CGSize(width: geometry.size.width + padding * 2,
                          height: geometry.size.height + padding * 2)

        guard size.width > 0, size.height > 0, let context = CGContext(
            data: nil, width: Int(size.width * key.scale), height: Int(size.height * key.scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.scaleBy(x: key.scale, y: key.scale)
        if key.lit {
            context.setShadow(offset: .zero, blur: key.glowRadius,
                              color: Theme.cgColor(hex: key.hex, alpha: theme.glowOpacity))
            context.setFillColor(accent)
        } else {
            context.setFillColor(Theme.cgColor(hex: key.hex, alpha: 0.08))
        }

        for index in 0..<geometry.segmentCount {
            context.addPath(CGPath(
                roundedRect: segmentRect(index, geometry: geometry, inset: padding),
                cornerWidth: geometry.cornerRadius, cornerHeight: geometry.cornerRadius,
                transform: nil
            ))
            // Filled one at a time when lit: a single fillPath over 40 subpaths casts one
            // shadow around the union, not one per segment.
            if key.lit { context.fillPath() }
        }
        if !key.lit { context.fillPath() }

        let image = context.makeImage()
        if let image { textureCache[key] = image }
        return image
    }

    private static func segmentRect(
        _ index: Int, geometry: MeterGeometry, inset: CGFloat
    ) -> CGRect {
        let offset = inset + CGFloat(index) * (geometry.segmentLength + geometry.segmentGap)
        return geometry.axis == .vertical
            ? CGRect(x: inset, y: offset, width: geometry.thickness, height: geometry.segmentLength)
            : CGRect(x: offset, y: inset, width: geometry.segmentLength, height: geometry.thickness)
    }

    static func invalidateTextureCache() {
        textureCache.removeAll()
    }

    // MARK: - Gate 12 (§13.7.12)

    /// Renders a single meter offscreen and reports where the lit run actually starts and
    /// ends, in points from the meter's origin.
    ///
    /// The orientation of a cropped layer is a platform convention rather than arithmetic, so
    /// it is verified against rendered pixels rather than reasoned about. Both axes, because
    /// the horizontal case is a second convention and not a consequence of the first.
    ///
    /// **What this catches, established by breaking it.** The first version of this check
    /// scanned only for the far end of the lit run and asserted its distance from the origin.
    /// Transliterating the vertical crop to `x: 1 - fraction` — the obvious bug — still
    /// passed, because `contentsGravity` draws the cropped sub-image against the layer's
    /// leading edge wherever the crop was taken from, and one slice of a uniform 40-segment
    /// texture looks like any other. The quantity that actually flips a horizontal meter is
    /// `contentsGravity` itself, so the scan now reports **both** ends: `origin` must sit at
    /// the meter's leading edge and `measured` is the run's length. A meter filled from the
    /// wrong end has the right length and the wrong origin, and only the pair separates
    /// them.
    static func selfCheck(
        value: Double, axis: MeterAxis, theme: Theme
    ) -> (expected: CGFloat, measured: CGFloat, origin: CGFloat)? {
        let geometry = axis == .vertical ? MeterGeometry.verticalMeter : .memoryMeter
        let meter = MeterLayer(geometry: geometry, accentHex: theme.accentCPU, theme: theme)

        let root = CALayer()
        let inset: CGFloat = 20
        root.frame = CGRect(x: 0, y: 0,
                            width: geometry.size.width + inset * 2,
                            height: geometry.size.height + inset * 2)
        root.backgroundColor = Theme.cgColor(hex: theme.background)
        meter.addTo(root)
        meter.updateScale(1)
        meter.layout(origin: CGPoint(x: inset, y: inset))

        let segments = min(max(Int((value * Double(geometry.segmentCount)).rounded()), 0),
                           geometry.segmentCount)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        meter.lit.isHidden = segments == 0
        meter.lit.contentsRect = contentsRect(litSegments: segments, geometry: geometry,
                                              glowRadius: theme.glowRadius)
        CATransaction.commit()

        guard let context = CGContext(
            data: nil, width: Int(root.bounds.width), height: Int(root.bounds.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        root.render(in: context)
        guard let data = context.data else { return nil }

        let bytes = data.bindMemory(to: UInt8.self,
                                    capacity: context.bytesPerRow * context.height)
        // BGRA byte order: blue, green, red, alpha. The accent is #39FF14.
        func isLit(x: Int, y: Int) -> Bool {
            let offset = y * context.bytesPerRow + x * 4
            return bytes[offset + 1] > 180 && bytes[offset + 2] < 140
        }

        let expected = segments == 0
            ? 0
            : CGFloat(segments) * geometry.segmentLength
                + CGFloat(segments - 1) * geometry.segmentGap

        switch axis {
        case .vertical:
            // Scan a column through the bar's centre. CGContext rows run top-down and the
            // layer's y runs bottom-up, so the topmost lit row is the run's far end and the
            // bottommost is its origin.
            let column = Int(meter.unlit.frame.midX)
            var topmost: Int?
            var bottommost: Int?
            for row in 0..<context.height where isLit(x: column, y: row) {
                if topmost == nil { topmost = row }
                bottommost = row
            }
            guard let topmost, let bottommost else { return nil }
            let farY = CGFloat(context.height - topmost)
            let originY = CGFloat(context.height - bottommost)
            return (expected, farY - originY, originY - meter.unlit.frame.minY)

        case .horizontal:
            // Scan a row through the bar's centre for both ends of the lit run.
            let row = context.height - Int(meter.unlit.frame.midY)
            var leftmost: Int?
            var rightmost: Int?
            for column in 0..<context.width where isLit(x: column, y: row) {
                if leftmost == nil { leftmost = column }
                rightmost = column
            }
            guard let leftmost, let rightmost else { return nil }
            return (
                expected,
                CGFloat(rightmost - leftmost),
                CGFloat(leftmost) - meter.unlit.frame.minX
            )
        }
    }
}
