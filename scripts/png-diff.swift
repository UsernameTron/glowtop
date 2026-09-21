// scripts/png-diff.swift
//
// Phase-09's parity instrument (SPEC.md §13.7 gate 12's companion). Compares two PNGs pixel
// by pixel, optionally inside one rect, and prints exactly one line of statistics:
//
//   size=WxH rect=x,y,w,h n=N match8=99.34% match4=98.10% maxdelta=71 differing=12043 bbox=x,y,w,h
//
// `match8` / `match4`: the fraction of compared pixels whose largest per-channel difference is
// ≤ 8 / ≤ 4. `maxdelta`: the largest per-channel difference seen. `differing`: pixels over 8.
// `bbox`: their bounding box in the image's own top-left-origin pixel space, `-` if none.
//
// Refuses -- exit 2, `png-diff: REFUSED <reason>`, never a statistic -- when the two images
// differ in pixel dimensions, either fails to load, or the rect falls outside the image. A
// statistic computed over a resized image is a number about the resize.
//
// Loose script, system frameworks only (`scripts/make-icon.swift`'s precedent). Each image is
// drawn 1:1 into a BGRA context in its **own** colour space, so no colour matching touches
// the bytes and the +6-red controlled-input arm (phase-09 plan, 1.2 step 4) reads exactly 6.
//
//   swift scripts/png-diff.swift <before.png> <after.png> [x y w h]

import CoreGraphics
import Foundation
import ImageIO

func refuse(_ reason: String) -> Never {
    print("png-diff: REFUSED \(reason)")
    exit(2)
}

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { refuse("cannot load \(path)") }
    return image
}

/// The image's bytes as premultipliedFirst / byteOrder32Little (BGRA), row 0 at the top.
func bitmap(_ image: CGImage) -> (bytes: [UInt8], bytesPerRow: Int) {
    let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { refuse("cannot create a bitmap context in the image's colour space") }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = context.data else { refuse("no bitmap") }
    let count = context.bytesPerRow * image.height
    let bytes = Array(UnsafeBufferPointer(
        start: data.bindMemory(to: UInt8.self, capacity: count), count: count
    ))
    return (bytes, context.bytesPerRow)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 7 else {
    refuse("usage: swift scripts/png-diff.swift <before.png> <after.png> [x y w h]")
}

let before = load(arguments[1])
let after = load(arguments[2])
guard before.width == after.width, before.height == after.height else {
    refuse("size mismatch \(before.width)x\(before.height) vs \(after.width)x\(after.height)")
}
let width = before.width, height = before.height

var rect = (x: 0, y: 0, w: width, h: height)
if arguments.count == 7 {
    guard let x = Int(arguments[3]), let y = Int(arguments[4]),
          let w = Int(arguments[5]), let h = Int(arguments[6])
    else { refuse("rect is not four integers") }
    guard x >= 0, y >= 0, w > 0, h > 0, x + w <= width, y + h <= height else {
        refuse("rect \(x),\(y),\(w),\(h) falls outside \(width)x\(height)")
    }
    rect = (x, y, w, h)
}

let a = bitmap(before)
let b = bitmap(after)

var n = 0, match8 = 0, match4 = 0, maxDelta = 0, differing = 0
var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
for y in rect.y..<(rect.y + rect.h) {
    for x in rect.x..<(rect.x + rect.w) {
        let oa = y * a.bytesPerRow + x * 4
        let ob = y * b.bytesPerRow + x * 4
        var delta = 0
        for channel in 0..<4 {
            delta = max(delta, abs(Int(a.bytes[oa + channel]) - Int(b.bytes[ob + channel])))
        }
        n += 1
        if delta <= 8 { match8 += 1 }
        if delta <= 4 { match4 += 1 }
        if delta > maxDelta { maxDelta = delta }
        if delta > 8 {
            differing += 1
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
}

let bbox = differing == 0 ? "-" : "\(minX),\(minY),\(maxX - minX + 1),\(maxY - minY + 1)"
print(String(
    format: "size=%dx%d rect=%d,%d,%d,%d n=%d match8=%.2f%% match4=%.2f%% maxdelta=%d differing=%d bbox=%@",
    width, height, rect.x, rect.y, rect.w, rect.h, n,
    Double(match8) / Double(n) * 100, Double(match4) / Double(n) * 100,
    maxDelta, differing, bbox
))
