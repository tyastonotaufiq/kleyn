// Renders the DMG window background: Design/DMG/background.tiff
//
// Run from the repository root:  swift Design/DMG/make-background.swift
//
// The TIFF holds a 1x and a 2x (Retina) image. Finder picks the right one.
// The layout must match scripts/dmg-settings.py: a 660×400 window with
// Kleyn centered at (165, 190) and Applications at (495, 190).

import AppKit

let width: CGFloat = 660
let height: CGFloat = 400
let iconY: CGFloat = 190          // icon centers, measured from the top
let leftX: CGFloat = 165
let rightX: CGFloat = 495
let iconSize: CGFloat = 128

let kleynBlue = NSColor(srgbRed: 0.0, green: 0.533, blue: 1.0, alpha: 1)
let ink = NSColor(srgbRed: 0.11, green: 0.15, blue: 0.22, alpha: 1)
let secondaryInk = NSColor(srgbRed: 0.33, green: 0.38, blue: 0.46, alpha: 1)

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)   // points, so the 2x rep reports 144 dpi

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // AppKit measures y from the bottom; Finder's icon positions measure from the top.
    func fromTop(_ y: CGFloat) -> CGFloat { height - y }

    // Background: a soft vertical gradient tinted with Kleyn's blue, lighter at the top.
    NSGradient(
        starting: NSColor(srgbRed: 0.87, green: 0.93, blue: 1.0, alpha: 1),
        ending: NSColor(srgbRed: 0.96, green: 0.98, blue: 1.0, alpha: 1)
    )!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

    // Headline and hint, centered near the top.
    func drawCentered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        let size = attributed.size()
        attributed.draw(in: NSRect(x: 0, y: fromTop(y) - size.height, width: width, height: size.height))
    }
    drawCentered("Drag Kleyn to Applications", y: 40,
                 font: .systemFont(ofSize: 22, weight: .semibold), color: ink)
    drawCentered("Then open Kleyn from your Applications folder.", y: 74,
                 font: .systemFont(ofSize: 13, weight: .regular), color: secondaryInk)

    // Arrow from Kleyn to Applications, between the two icons.
    let gap: CGFloat = 30
    let start = NSPoint(x: leftX + iconSize / 2 + gap, y: fromTop(iconY))
    let tip = NSPoint(x: rightX - iconSize / 2 - gap, y: fromTop(iconY))
    let head: CGFloat = 16

    kleynBlue.setStroke()
    let shaft = NSBezierPath()
    shaft.lineWidth = 6
    shaft.lineCapStyle = .round
    shaft.move(to: start)
    shaft.line(to: NSPoint(x: tip.x - head * 0.6, y: tip.y))
    shaft.stroke()

    kleynBlue.setFill()
    let arrowHead = NSBezierPath()
    arrowHead.move(to: tip)
    arrowHead.line(to: NSPoint(x: tip.x - head * 1.3, y: tip.y - head))
    arrowHead.line(to: NSPoint(x: tip.x - head * 1.3, y: tip.y + head))
    arrowHead.close()
    arrowHead.lineJoinStyle = .round
    arrowHead.lineWidth = 4
    arrowHead.fill()
    arrowHead.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("kleyn-dmg-background-\(ProcessInfo.processInfo.processIdentifier)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

var pngs: [String] = []
for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    let url = temporary.appendingPathComponent(name)
    try render(scale: scale).representation(using: .png, properties: [:])!.write(to: url)
    pngs.append(url.path)
}

// Combine both resolutions into one TIFF, which Finder uses for Retina displays.
let output = directory.appendingPathComponent("background.tiff").path
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck"] + pngs + ["-out", output]
try tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else { fatalError("tiffutil failed") }
print("Wrote \(output)")
