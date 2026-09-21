// scripts/make-icon.swift
//
// GlowTop.app's icon (SPEC.md §2.8 packaging). Colours are hardcoded from §7.2's Neon
// preset — `background` #0B0B0F, `accentCPU` #39FF14 — because this is a loose script,
// not a package target, and cannot import GlowTopCore without dragging build products
// into a Swift-scripting run. Keeping it loose means no target in Package.swift gains
// CoreGraphics/ImageIO (§2.7's table stays unchanged).
//
// Draws a rounded-rect ground with three ascending bars and a soft glow, at every size
// a macOS .iconset needs, then shells out to `iconutil` for the .icns.
//
// Run from the repo root: `swift scripts/make-icon.swift`
// (or, if interpreter mode is slow: `swiftc -O -o /tmp/glowtop-icon scripts/make-icon.swift
// && /tmp/glowtop-icon`)

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Resolve the repo root from this script's own path so it works regardless of cwd.
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconsetDir = repoRoot.appendingPathComponent("build/GlowTop.iconset")
let icnsPath = repoRoot.appendingPathComponent("build/GlowTop.icns")

try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// §7.2's Neon preset: `background` and `accentCPU`.
let groundColor = CGColor(red: 0x0B / 255.0, green: 0x0B / 255.0, blue: 0x0F / 255.0, alpha: 1)
let barColor = CGColor(red: 0x39 / 255.0, green: 0xFF / 255.0, blue: 0x14 / 255.0, alpha: 1)

func drawIcon(pixels: Int) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let size = CGFloat(pixels)

    // Rounded-rect ground, inset so the glow has room to breathe.
    let inset = size * 0.04
    let groundRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let groundPath = CGPath(
        roundedRect: groundRect, cornerWidth: size * 0.22, cornerHeight: size * 0.22, transform: nil
    )
    ctx.addPath(groundPath)
    ctx.setFillColor(groundColor)
    ctx.fillPath()

    // Three ascending bars, glowing.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: size * 0.06, color: barColor)
    ctx.setFillColor(barColor)
    let barWidth = size * 0.14
    let gap = size * 0.08
    let heights: [CGFloat] = [size * 0.28, size * 0.42, size * 0.56]
    let totalWidth = barWidth * 3 + gap * 2
    var x = (size - totalWidth) / 2
    let baseline = size * 0.22
    for h in heights {
        let bar = CGRect(x: x, y: baseline, width: barWidth, height: h)
        let barPath = CGPath(
            roundedRect: bar, cornerWidth: barWidth * 0.3, cornerHeight: barWidth * 0.3, transform: nil
        )
        ctx.addPath(barPath)
        ctx.fillPath()
        x += barWidth + gap
    }
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        FileHandle.standardError.write(Data("make-icon: failed to create PNG destination for \(url.path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write(Data("make-icon: failed to write \(url.path)\n".utf8))
        exit(1)
    }
}

// The standard .iconset: five named sizes, each at 1x and 2x.
let sizes = [16, 32, 128, 256, 512]
for base in sizes {
    writePNG(drawIcon(pixels: base), to: iconsetDir.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(drawIcon(pixels: base * 2), to: iconsetDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsPath.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("make-icon: iconutil failed with status \(iconutil.terminationStatus)\n".utf8))
    exit(1)
}

print("make-icon: wrote \(icnsPath.path)")
