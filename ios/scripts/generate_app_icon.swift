#!/usr/bin/env swift
//
// Generates the Cleave app icon: a bold white "¢" over a faint rising chart-line motif on an
// indigo → teal gradient. Output is a 1024×1024, opaque (no alpha), sRGB PNG - the App Store marketing
// icon (Xcode derives all device sizes from it).
//
// Usage:  swift ios/scripts/generate_app_icon.swift <out.png>
//
import CoreGraphics
import CoreText
import Foundation
import ImageIO

let size = 1024
let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Cleave/Assets.xcassets/AppIcon.appiconset/Icon-1024.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
// noneSkipLast => 32-bit RGBx with the alpha byte ignored, so the written PNG has no alpha channel.
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("could not create context") }

let w = CGFloat(size), h = CGFloat(size)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// MARK: Background gradient (indigo top-left → teal bottom-right)
let indigo = rgb(0x3B / 255, 0x2F / 255, 0x8F / 255)
let teal = rgb(0x14 / 255, 0xB8 / 255, 0xA6 / 255)
let gradient = CGGradient(colorsSpace: space, colors: [indigo, teal] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h),
                       end: CGPoint(x: w, y: 0), options: [])

// MARK: Chart motif - faint gridlines + a rising trend line with an area fill under it.
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// Horizontal gridlines.
ctx.setStrokeColor(rgb(1, 1, 1, 0.08))
ctx.setLineWidth(4)
for i in 1...4 {
    let y = h * CGFloat(i) / 5
    ctx.move(to: CGPoint(x: w * 0.08, y: y))
    ctx.addLine(to: CGPoint(x: w * 0.92, y: y))
}
ctx.strokePath()

// Rising zig-zag trend (left→right, generally up). Points in icon space (origin bottom-left).
let pts = [
    CGPoint(x: 0.10, y: 0.30), CGPoint(x: 0.27, y: 0.46), CGPoint(x: 0.42, y: 0.36),
    CGPoint(x: 0.58, y: 0.60), CGPoint(x: 0.74, y: 0.52), CGPoint(x: 0.90, y: 0.78),
].map { CGPoint(x: $0.x * w, y: $0.y * h) }

// Area fill beneath the trend.
ctx.beginPath()
ctx.move(to: CGPoint(x: pts[0].x, y: 0))
for p in pts { ctx.addLine(to: p) }
ctx.addLine(to: CGPoint(x: pts.last!.x, y: 0))
ctx.closePath()
ctx.setFillColor(rgb(1, 1, 1, 0.06))
ctx.fillPath()

// Trend stroke.
ctx.setStrokeColor(rgb(1, 1, 1, 0.16))
ctx.setLineWidth(16)
ctx.move(to: pts[0])
for p in pts.dropFirst() { ctx.addLine(to: p) }
ctx.strokePath()

// MARK: Centered "¢"
let glyphColor = rgb(1, 1, 1, 1)
let fontNames = ["AvenirNext-DemiBold", "AvenirNext-Medium", "Helvetica"]
let pointSize: CGFloat = 1000
let font = fontNames.lazy
    .map { CTFontCreateWithName($0 as CFString, pointSize, nil) }
    .first { _ in true }!

let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: glyphColor] as CFDictionary
let attributed = CFAttributedStringCreate(nil, "¢" as CFString, attrs)!
let line = CTLineCreateWithAttributedString(attributed)
// Tight glyph-path bounds for precise optical centering.
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
let tx = (w - bounds.width) / 2 - bounds.minX
let ty = (h - bounds.height) / 2 - bounds.minY

ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
              color: rgb(0, 0, 0, 0.28))
ctx.textPosition = CGPoint(x: tx, y: ty)
CTLineDraw(line, ctx)

// MARK: Write PNG (no alpha)
guard let image = ctx.makeImage() else { fatalError("could not render image") }
let url = URL(fileURLWithPath: out)
try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let dest = CGImageDestinationCreateWithURL(
    url as CFURL, "public.png" as CFString, 1, nil) else { fatalError("could not create destination") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out)") }
print("wrote \(out) (\(size)x\(size))")
