#!/usr/bin/env swift
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let colors = (
    dark: NSColor(calibratedRed: 0.20, green: 0.57, blue: 0.86, alpha: 1),
    light: NSColor(calibratedRed: 0.55, green: 0.82, blue: 0.97, alpha: 1),
    ink: NSColor(calibratedRed: 0.08, green: 0.32, blue: 0.54, alpha: 1)
)
func draw(size: Int, at url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.imageInterpolation = .high
    let base = NSBezierPath(roundedRect: NSRect(x: 94, y: 94, width: 836, height: 836), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.20); shadow.set()
    colors.dark.setFill(); base.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: colors.light, ending: colors.dark)!.draw(in: base, angle: -75)
    let sheen = NSBezierPath(roundedRect: NSRect(x: 106, y: 106, width: 812, height: 812), xRadius: 176, yRadius: 176)
    NSColor.white.withAlphaComponent(0.13).setStroke(); sheen.lineWidth = 3; sheen.stroke()

    let paper = NSBezierPath()
    paper.move(to: NSPoint(x: 340, y: 260)); paper.line(to: NSPoint(x: 657, y: 260))
    paper.curve(to: NSPoint(x: 691, y: 294), controlPoint1: NSPoint(x: 680, y: 260), controlPoint2: NSPoint(x: 691, y: 272))
    paper.line(to: NSPoint(x: 691, y: 650)); paper.line(to: NSPoint(x: 566, y: 777)); paper.line(to: NSPoint(x: 340, y: 777))
    paper.curve(to: NSPoint(x: 306, y: 743), controlPoint1: NSPoint(x: 317, y: 777), controlPoint2: NSPoint(x: 306, y: 765))
    paper.line(to: NSPoint(x: 306, y: 294)); paper.curve(to: NSPoint(x: 340, y: 260), controlPoint1: NSPoint(x: 306, y: 272), controlPoint2: NSPoint(x: 317, y: 260)); paper.close()
    NSGraphicsContext.saveGraphicsState()
    let paperShadow = NSShadow(); paperShadow.shadowColor = .black.withAlphaComponent(0.18)
    paperShadow.shadowBlurRadius = 26; paperShadow.shadowOffset = NSSize(width: 0, height: -13); paperShadow.set()
    NSColor.white.setFill(); paper.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: .white, ending: NSColor(calibratedWhite: 0.91, alpha: 1))!.draw(in: paper, angle: -90)
    let fold = NSBezierPath(); fold.move(to: NSPoint(x: 566, y: 777)); fold.line(to: NSPoint(x: 566, y: 686))
    fold.curve(to: NSPoint(x: 603, y: 650), controlPoint1: NSPoint(x: 566, y: 659), controlPoint2: NSPoint(x: 577, y: 650))
    fold.line(to: NSPoint(x: 691, y: 650)); fold.close()
    NSColor(calibratedRed: 0.77, green: 0.88, blue: 0.96, alpha: 1).setFill(); fold.fill()
    ("TXT" as NSString).draw(at: NSPoint(x: 356, y: 478), withAttributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 86, weight: .bold), .foregroundColor: colors.ink
    ])
    for (y, width) in [(433.0, 210.0), (393.0, 148.0)] {
        colors.ink.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: NSRect(x: 359, y: y, width: width, height: 13), xRadius: 6, yRadius: 6).fill()
    }

    let cursor = NSBezierPath()
    cursor.move(to: NSPoint(x: 645, y: 459)); cursor.line(to: NSPoint(x: 647, y: 237))
    cursor.line(to: NSPoint(x: 698, y: 285)); cursor.line(to: NSPoint(x: 742, y: 202))
    cursor.line(to: NSPoint(x: 781, y: 224)); cursor.line(to: NSPoint(x: 737, y: 307))
    cursor.line(to: NSPoint(x: 809, y: 318)); cursor.close()
    NSGraphicsContext.saveGraphicsState()
    let cursorShadow = NSShadow(); cursorShadow.shadowColor = .black.withAlphaComponent(0.18)
    cursorShadow.shadowBlurRadius = 16; cursorShadow.shadowOffset = NSSize(width: 0, height: -5); cursorShadow.set()
    NSColor.white.setStroke(); cursor.lineJoinStyle = .round; cursor.lineWidth = 17; cursor.stroke()
    colors.ink.setFill(); cursor.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(points)x\(points)@\(scale)x.png"
        try draw(size: points * scale, at: output.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
    }
}
let data = try JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
try data.write(to: output.appendingPathComponent("Contents.json"))
print("Generated all macOS AppIcon sizes.")
