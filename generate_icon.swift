import AppKit

// Generates AppIcon.icns for Jorvik Daily News: a newspaper-masthead style
// tile — deep ink gradient background with a large white Didot "N" and two
// thin off-white rules above and below, echoing a broadsheet nameplate.
// Replace by dropping your own AppIcon.icns next to this file.

let sizes: [CGFloat] = [16, 32, 64, 128, 256, 512, 1024]
let outDir = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: outDir)
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for size in sizes {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.22
    let clipPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    clipPath.addClip()

    // Background: deep ink gradient, newspaper-black with a hint of navy
    let bg = NSGradient(colors: [
        NSColor(srgbRed: 0.09, green: 0.11, blue: 0.17, alpha: 1.0),
        NSColor(srgbRed: 0.04, green: 0.05, blue: 0.09, alpha: 1.0)
    ])!
    bg.draw(in: rect, angle: -90)

    // Masthead rules — off-white horizontal bars above and below the glyph.
    // Skipped at the smallest sizes where they'd blur.
    if size >= 32 {
        let ruleInset = size * 0.16
        let ruleThickness = max(1, size * 0.009)
        let topRuleY = size * 0.735
        let bottomRuleY = size * 0.245
        NSColor(white: 0.88, alpha: 0.9).setFill()
        NSBezierPath(rect: NSRect(
            x: ruleInset, y: topRuleY,
            width: size - 2 * ruleInset, height: ruleThickness
        )).fill()
        NSBezierPath(rect: NSRect(
            x: ruleInset, y: bottomRuleY,
            width: size - 2 * ruleInset, height: ruleThickness
        )).fill()
    }

    // Central glyph: Didot "N"
    let letter = "N" as NSString
    let fontSize = size * 0.62
    let font = NSFont(name: "Didot", size: fontSize)
        ?? NSFont(name: "Bodoni 72", size: fontSize)
        ?? NSFont(name: "Georgia-Bold", size: fontSize)
        ?? NSFont.boldSystemFont(ofSize: fontSize)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(white: 0.96, alpha: 1.0),
        .paragraphStyle: paragraph
    ]
    let textSize = letter.size(withAttributes: attributes)
    let textRect = NSRect(
        x: (size - textSize.width) / 2,
        y: (size - textSize.height) / 2 - size * 0.035,
        width: textSize.width,
        height: textSize.height
    )
    letter.draw(in: textRect, withAttributes: attributes)

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to render PNG at size \(size)")
    }

    let oneX = outDir.appendingPathComponent("icon_\(Int(size))x\(Int(size)).png")
    try! png.write(to: oneX)
    if size >= 32 {
        let halfSize = Int(size) / 2
        let twoX = outDir.appendingPathComponent("icon_\(halfSize)x\(halfSize)@2x.png")
        try! png.write(to: twoX)
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "AppIcon.iconset", "-o", "AppIcon.icns"]
try! task.run()
task.waitUntilExit()

try? FileManager.default.removeItem(at: outDir)
print("Generated AppIcon.icns")
