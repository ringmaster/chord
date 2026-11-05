// Draws Chord's application icon and writes an .iconset folder.
//
// Usage: make-icon <output.iconset>
// Run through `make icon`, which turns the folder into App/Resources/AppIcon.icns.
//
// The icon is a blue disc with its right side cut flat, on a white rounded
// square. All sizes come from the same drawing, so each stays sharp.

import AppKit

/// Draws the icon into a square of `size` points.
func drawIcon(size: CGFloat, in context: CGContext) {
    let unit = size / 1024
    // The macOS icon grid: an 824-point rounded square centered in 1024.
    let tile = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil)

    // The tile: white with a faint cool shade toward the bottom, and a soft shadow.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 28 * unit,
                      color: CGColor(gray: 0, alpha: 0.28))
    context.addPath(tilePath)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let tileShade = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        CGColor(srgbRed: 0.93, green: 0.95, blue: 0.98, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(tileShade, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    context.restoreGState()

    // The disc, cut flat on the right. Its center sits right of the tile's
    // center, so the cut shape as a whole looks centered.
    let radius = 330 * unit
    let center = CGPoint(x: 540 * unit, y: 512 * unit)
    let cutX = center.x + radius * 0.56
    let disc = CGMutablePath()
    disc.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    let keep = CGRect(x: 0, y: 0, width: cutX, height: size)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8 * unit), blur: 22 * unit,
                      color: CGColor(srgbRed: 0.02, green: 0.12, blue: 0.6, alpha: 0.35))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.clip(to: keep)
    context.addPath(disc)
    context.clip()

    // Light cyan blue at the top left to deep blue at the bottom right.
    let blue = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.33, green: 0.80, blue: 1.00, alpha: 1),
        CGColor(srgbRed: 0.03, green: 0.42, blue: 1.00, alpha: 1),
        CGColor(srgbRed: 0.02, green: 0.12, blue: 0.78, alpha: 1),
    ] as CFArray, locations: [0, 0.45, 1])!
    context.drawLinearGradient(blue,
                               start: CGPoint(x: center.x - radius * 0.8, y: center.y + radius * 0.9),
                               end: CGPoint(x: center.x + radius * 0.6, y: center.y - radius),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // A soft gloss across the upper left, as on glass.
    let gloss = CGMutablePath()
    gloss.addEllipse(in: CGRect(x: center.x - radius * 1.5, y: center.y + radius * 0.05,
                                width: radius * 2.4, height: radius * 1.7))
    context.addPath(gloss)
    context.clip()
    let shine = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(shine, start: CGPoint(x: center.x - radius, y: center.y + radius),
                               end: CGPoint(x: center.x, y: center.y), options: [])
    context.endTransparencyLayer()
    context.restoreGState()
}

func writePNG(pixels: Int, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    drawIcon(size: CGFloat(pixels), in: context)
    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <output.iconset>\n".utf8))
    exit(2)
}
let folder = URL(filePath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try writePNG(pixels: points, to: folder.appending(path: "icon_\(points)x\(points).png"))
    try writePNG(pixels: points * 2, to: folder.appending(path: "icon_\(points)x\(points)@2x.png"))
}
