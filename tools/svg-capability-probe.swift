// Does AppKit's SVG rep resolve anything external?
//
// The reader draws an article's inline <svg> with `NSImage(data:)`, which
// yields an `_NSSVGImageRep`. That is a closed Apple parser, so what it will
// and will not fetch is a property of the OS rather than of this app — and
// estate memory already records ImageIO behaviour changing under macOS 27. It
// therefore has to be re-measured on each OS the app supports, not reasoned
// about once.
//
// Measured on macOS 26.6.2, 2026-09-10: NOTHING external resolves. No network
// request from `<image xlink:href>`, `<image href>`, `<use href>`, CSS
// `@import`, `url()`, `<script>` or `onload`; no local file read via `file://`
// or an external DTD entity. The three `<image>` cases each paint the same
// 1,976 pixels — a placeholder for an unresolvable image — against 40,000 for
// the control.
//
// TO RUN
//   python3 -m http.server 8931 --bind 127.0.0.1 > server.log 2>&1 &
//   # write known.png (a solid magenta 64x64) and secret.txt beside this file
//   xcrun swiftc -O -o svgprobe svg-capability-probe.swift && ./svgprobe
//   grep -oE "probe-[a-z0-9-]+" server.log   # any hit is a finding
//
// A pixel count is the test, not whether NSImage returned non-nil: it returns
// an image for every case here, including the ones that resolved nothing.

import AppKit

let dir = FileManager.default.currentDirectoryPath
let port = "8931"

/// Render an SVG exactly as the app does, then rasterise and count what was
/// painted. A pixel count is the only honest test of "did it draw the file".
func render(_ svg: String) -> (made: Bool, painted: Int, magenta: Int) {
    guard let data = svg.data(using: .utf8),
          let image = NSImage(data: data) else { return (false, 0, 0) }
    let side = 200
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: side * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()

    var painted = 0, magenta = 0
    for y in 0..<side {
        for x in 0..<side {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
            if r < 0.97 || g < 0.97 || b < 0.97 { painted += 1 }
            if r > 0.8, g < 0.2, b > 0.8 { magenta += 1 }
        }
    }
    return (true, painted, magenta)
}

let cases: [(String, String)] = [
    ("a. <image xlink:href> over http",
     "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' "
     + "width='200' height='200'><image xlink:href='http://127.0.0.1:\(port)/probe-a.png' "
     + "x='0' y='0' width='200' height='200'/></svg>"),

    ("b. <image href> over http",
     "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'>"
     + "<image href='http://127.0.0.1:\(port)/probe-b.png' x='0' y='0' width='200' height='200'/></svg>"),

    ("c. <image href> to a local file",
     "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'>"
     + "<image href='file://\(dir)/known.png' x='0' y='0' width='200' height='200'/></svg>"),

    ("d. <use href> to a remote fragment",
     "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'>"
     + "<use href='http://127.0.0.1:\(port)/probe-d.svg#shape' x='0' y='0'/></svg>"),

    ("e. CSS @import and a url() background",
     "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'>"
     + "<style>@import url('http://127.0.0.1:\(port)/probe-e.css');"
     + "rect{fill:url('http://127.0.0.1:\(port)/probe-e2.png')}</style>"
     + "<rect width='200' height='200'/></svg>"),

    ("f. DTD external entity to a local file",
     "<?xml version='1.0'?><!DOCTYPE svg [<!ENTITY xxe SYSTEM 'file://\(dir)/secret.txt'>]>"
     + "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'>"
     + "<text x='10' y='100' font-size='20'>&xxe;</text></svg>"),

    ("g. script and onload",
     "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200' "
     + "onload=\"fetch('http://127.0.0.1:\(port)/probe-g-onload')\">"
     + "<script>fetch('http://127.0.0.1:\(port)/probe-g-script')</script>"
     + "<rect width='200' height='200' fill='black'/></svg>"),

    ("h. control: a plain local shape",
     "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'>"
     + "<rect width='200' height='200' fill='#ff00ff'/></svg>")
]

print("  case                                        NSImage  painted  magenta")
for (name, svg) in cases {
    let r = render(svg)
    print("  " + name.padding(toLength: 42, withPad: " ", startingAt: 0)
          + "  " + (r.made ? "yes   " : "NO    ")
          + "  " + String(format: "%7d", r.painted)
          + "  " + String(format: "%7d", r.magenta))
}
