// Draws Chord's application icon and writes an .iconset folder.
//
// Usage: make-icon <artwork.png> <output.iconset>
// Run through `make icon`, which turns the folder into App/Resources/AppIcon.icns.
//
// The icon is Owen's artwork, a blue disc with its right side cut flat, on a
// white rounded square. The tile is drawn in code at each size.

import AppKit

/// Draws the icon into a square of `size` points.
func drawIcon(size: CGFloat, artwork: CGImage, in context: CGContext) {
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

    // The artwork: the blue disc cut flat on the right, from artwork.png. Its
    // canvas has transparent margins, so it is drawn over the whole tile. A
    // soft blue shadow lifts it from the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8 * unit), blur: 22 * unit,
                      color: CGColor(srgbRed: 0.02, green: 0.12, blue: 0.6, alpha: 0.35))
    context.interpolationQuality = .high
    context.draw(artwork, in: tile)
    context.restoreGState()
}

func writePNG(pixels: Int, artwork: CGImage, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    drawIcon(size: CGFloat(pixels), artwork: artwork, in: context)
    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon <artwork.png> <output.iconset>\n".utf8))
    exit(2)
}
guard let source = CGImageSourceCreateWithURL(URL(filePath: CommandLine.arguments[1]) as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("make-icon: cannot read \(CommandLine.arguments[1])\n".utf8))
    exit(1)
}
let folder = URL(filePath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try writePNG(pixels: points, artwork: artwork, to: folder.appending(path: "icon_\(points)x\(points).png"))
    try writePNG(pixels: points * 2, artwork: artwork, to: folder.appending(path: "icon_\(points)x\(points)@2x.png"))
}
