// Draws Clacky's app icon (a white keycap with a colored c on a colored tile) at every size macOS
// uses and packs it into Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift                      write Resources/AppIcon.icns
//   swift scripts/make-icon.swift --color 2F9E8F       try another tile color
//   swift scripts/make-icon.swift --preview out.png    also save the 1024 px artwork
//   swift scripts/make-icon.swift --no-icns ...        only the preview, leave AppIcon.icns alone
//   swift scripts/make-icon.swift --framed             old-style artwork: rounded tile, margins, shadow
//
// Each size is drawn from vectors rather than scaled down from 1024, so small sizes stay crisp.
// The artwork is a full-bleed square: macOS 26 cuts the rounded shape itself, but shrinks old-style
// artwork (rounded tile + margins + shadow) into an extra frame. macOS 15 and earlier don't round
// icons, so for those, build with --framed.
import AppKit
import CoreText
import Foundation

/// The color Clacky ships with. Change it here, or pass --color to try others.
let defaultTile = "F0592A"  // tangerine, the app's accent; the old graphite was 2B2D33

struct RGB {
    var r, g, b: Double
    init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        r = Double((value >> 16) & 0xFF) / 255; g = Double((value >> 8) & 0xFF) / 255; b = Double(value & 0xFF) / 255
    }
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}
let white = RGB(r: 1, g: 1, b: 1)
let tileRGB = RGB(hex: option("--color") ?? defaultTile)
// The c is the tile color, darkened only as far as it takes to stand out on the white key (3:1).
var legendRGB = tileRGB
while (1.05 / (legendRGB.luminance + 0.05)) < 3 { legendRGB = legendRGB.mixed(with: RGB(r: 0, g: 0, b: 0), 0.05) }

let framed = arguments.contains("--framed")
let tileColor = tileRGB.cgColor
let legendColor = legendRGB.cgColor
let keycapSide = tileRGB.mixed(with: white, 0.72).cgColor  // keycap walls: a pale tint of the tile
let keycapTop = white.cgColor

/// The macOS tile: a superellipse, close to Apple's continuous-corner shape.
func tilePath(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let exponent: CGFloat = 5
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + rect.width / 2 * copysign(pow(abs(c), 2 / exponent), c)
        let y = rect.midY + rect.height / 2 * copysign(pow(abs(s), 2 / exponent), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func render(size: Int) -> CGImage {
    let px = CGFloat(size)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // The design is drawn in a 100-unit square (y down, like the canvas) that maps onto the tile.
    let scale = px / 1024
    let tile = framed
        ? CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
        : CGRect(x: 0, y: 0, width: px, height: px)
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        let u = tile.width / 100
        return CGRect(x: tile.minX + x * u, y: px - (tile.minY + (y + h) * u), width: w * u, height: h * u)
    }
    func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        let rr = radius * tile.width / 100
        return CGPath(roundedRect: r, cornerWidth: rr, cornerHeight: rr, transform: nil)
    }

    if framed {
        // Tile with the standard soft drop shadow.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale,
                          color: CGColor(gray: 0, alpha: 0.28))
        context.addPath(tilePath(in: tile))
        context.setFillColor(tileColor)
        context.fillPath()
        context.restoreGState()
    } else {
        // Full-bleed square: the system cuts the rounded shape itself.
        context.setFillColor(tileColor)
        context.fill(tile)
    }

    // Keycap: walls, then the top face, shifted up so the front wall shows.
    context.addPath(roundedRect(rect(18, 18, 64, 66), 14))
    context.setFillColor(keycapSide)
    context.fillPath()
    context.addPath(roundedRect(rect(25, 20, 50, 52), 10))
    context.setFillColor(keycapTop)
    context.fillPath()

    // The c legend, centered on the top face (design center: x 50, y 45.6), in the system rounded font.
    let fontSize = 40 * tile.width / 100
    let base = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    let rounded = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
    var glyph: CGGlyph = 0
    var character: UniChar = UniChar(UInt8(ascii: "c"))
    CTFontGetGlyphsForCharacters(rounded as CTFont, &character, &glyph, 1)
    if let glyphPath = CTFontCreatePathForGlyph(rounded as CTFont, glyph, nil) {
        let box = glyphPath.boundingBoxOfPath
        let target = rect(50, 45.6, 0, 0).origin
        var move = CGAffineTransform(translationX: target.x - box.midX, y: target.y - box.midY)
        if let placed = glyphPath.copy(using: &move) {
            context.addPath(placed)
            context.setFillColor(legendColor)
            context.fillPath()
        }
    }
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try data.write(to: url)
}

if let preview = option("--preview") {
    try writePNG(render(size: 1024), to: URL(fileURLWithPath: preview))
    print("wrote \(preview)")
}
if arguments.contains("--no-icns") { exit(0) }

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Clacky-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    try writePNG(render(size: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try writePNG(render(size: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(output.path)")
