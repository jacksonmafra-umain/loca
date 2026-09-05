import AppKit
import CoreGraphics
import Foundation

// Draws Loca's app icon at every size macOS asks for.
//
// Generated rather than committed as a binary, for the same reason there is no
// Xcode project: an icon nobody can regenerate is an icon nobody can change.
// The palette lives here in one place, so a change to the brand is a change to
// four constants.
//
//   swift Tools/GenerateAppIcon.swift <output.iconset>
//
// The mark is a padlock whose body is an address bar. Both halves of what Loca
// does — a local address, served over HTTPS — in a shape that still reads at
// sixteen pixels, where a globe or a chain link turns to mush.

enum Palette {
    static let groundTop = CGColor(red: 0.239, green: 0.239, blue: 0.322, alpha: 1)  // #3D3D52
    static let groundBottom = CGColor(red: 0.129, green: 0.129, blue: 0.180, alpha: 1)  // #21212E
    static let accent = CGColor(red: 0.949, green: 0.286, blue: 0.047, alpha: 1)  // #F2490C
    static let paper = CGColor(red: 0.949, green: 0.949, blue: 0.949, alpha: 1)  // #F2F2F2
    static let keyhole = CGColor(red: 0.180, green: 0.180, blue: 0.251, alpha: 1)  // #2E2E40
}

/// Everything is expressed against a 1024 canvas and scaled, so proportions
/// hold at every size rather than being retuned per export.
enum Geometry {
    static let canvas: CGFloat = 1024

    /// macOS leaves a margin around the rounded square; the artwork does not
    /// run to the edge of the file.
    static let inset: CGFloat = 100
    static var plate: CGRect {
        CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    }
    /// The Big Sur corner proportion.
    static var plateRadius: CGFloat { plate.width * 0.2237 }

    /// Wider than it is tall, so it reads as an address bar as well as a lock
    /// body. A square here is just a padlock.
    static let bodyWidth: CGFloat = 510
    static let bodyHeight: CGFloat = 292
    static let bodyRadius: CGFloat = 72
    static let bodyCentreY: CGFloat = 414

    static let shackleStroke: CGFloat = 76
    static let shackleOuterWidth: CGFloat = 300
    static let shackleTopY: CGFloat = 764
}

func drawIcon(into context: CGContext) {
    let canvas = Geometry.canvas
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // MARK: The rounded plate

    let plate = CGPath(
        roundedRect: Geometry.plate,
        cornerWidth: Geometry.plateRadius,
        cornerHeight: Geometry.plateRadius,
        transform: nil)

    context.saveGState()
    context.addPath(plate)
    context.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [Palette.groundTop, Palette.groundBottom] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: canvas),
        end: CGPoint(x: 0, y: 0),
        options: [])
    context.restoreGState()

    // MARK: The shackle
    //
    // Drawn before the body so the body covers where the legs end, which is
    // what makes the two read as one object rather than an arch beside a box.

    let centreX = canvas / 2
    let shackleRadius = (Geometry.shackleOuterWidth - Geometry.shackleStroke) / 2
    let shackleCentreY = Geometry.shackleTopY - shackleRadius

    let shackle = CGMutablePath()
    // Clockwise, because this context has its origin at the bottom left: going
    // counterclockwise from π to 0 sweeps through 270° and draws the *bottom*
    // half, which turns the arch into a pair of horns.
    shackle.addArc(
        center: CGPoint(x: centreX, y: shackleCentreY),
        radius: shackleRadius,
        startAngle: .pi,
        endAngle: 0,
        clockwise: true)
    // Down into the body. The overlap is deliberate.
    shackle.move(to: CGPoint(x: centreX - shackleRadius, y: shackleCentreY))
    shackle.addLine(to: CGPoint(x: centreX - shackleRadius, y: Geometry.bodyCentreY))
    shackle.move(to: CGPoint(x: centreX + shackleRadius, y: shackleCentreY))
    shackle.addLine(to: CGPoint(x: centreX + shackleRadius, y: Geometry.bodyCentreY))

    context.setStrokeColor(Palette.accent)
    context.setLineWidth(Geometry.shackleStroke)
    context.setLineCap(.round)
    context.addPath(shackle)
    context.strokePath()

    // MARK: The body, which is also an address bar

    let body = CGRect(
        x: centreX - Geometry.bodyWidth / 2,
        y: Geometry.bodyCentreY - Geometry.bodyHeight / 2,
        width: Geometry.bodyWidth,
        height: Geometry.bodyHeight)

    context.setFillColor(Palette.paper)
    context.addPath(
        CGPath(
            roundedRect: body,
            cornerWidth: Geometry.bodyRadius,
            cornerHeight: Geometry.bodyRadius,
            transform: nil))
    context.fillPath()

    // MARK: The keyhole
    //
    // A circle over a tapering stem. Small enough to disappear below about
    // 32 pixels, which is fine: by then the silhouette is doing the work.

    let keyholeCentre = CGPoint(x: centreX, y: Geometry.bodyCentreY + 26)
    let keyholeRadius: CGFloat = 46

    context.setFillColor(Palette.keyhole)
    context.addEllipse(
        in: CGRect(
            x: keyholeCentre.x - keyholeRadius,
            y: keyholeCentre.y - keyholeRadius,
            width: keyholeRadius * 2,
            height: keyholeRadius * 2))
    context.fillPath()

    let stem = CGMutablePath()
    stem.move(to: CGPoint(x: keyholeCentre.x - 30, y: keyholeCentre.y))
    stem.addLine(to: CGPoint(x: keyholeCentre.x + 30, y: keyholeCentre.y))
    stem.addLine(to: CGPoint(x: keyholeCentre.x + 18, y: keyholeCentre.y - 92))
    stem.addLine(to: CGPoint(x: keyholeCentre.x - 18, y: keyholeCentre.y - 92))
    stem.closeSubpath()

    context.setFillColor(Palette.keyhole)
    context.addPath(stem)
    context.fillPath()
}

func render(size: CGFloat) -> Data? {
    let pixels = Int(size)
    guard
        let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    let scale = size / Geometry.canvas
    context.scaleBy(x: scale, y: scale)
    drawIcon(into: context)

    guard let image = context.makeImage() else { return nil }
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: pixels, height: pixels)
    return representation.representation(using: .png, properties: [:])
}

// MARK: - Export

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("usage: GenerateAppIcon.swift <output.iconset>\n".utf8))
    exit(2)
}

let iconset = URL(filePath: arguments[1])
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The exact set `iconutil` expects. A missing size is a silent quality loss at
// whichever place macOS wanted it.
let exports: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for export in exports {
    guard let data = render(size: export.size) else {
        FileHandle.standardError.write(Data("could not render \(export.name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconset.appending(path: export.name))
}

print("wrote \(exports.count) images to \(iconset.path(percentEncoded: false))")
