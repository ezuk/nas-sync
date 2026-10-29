// Draws the app icon set: two stacked drive outlines on a dark rounded square.
// Usage: swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let out = URL(filePath: CommandLine.arguments[1])
var entries: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(px)
        let inset = s * 0.1
        let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        NSGradient(starting: NSColor(white: 0.24, alpha: 1), ending: NSColor(white: 0.1, alpha: 1))!
            .draw(in: NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18), angle: -90)
        NSColor.white.setStroke()
        let w = s * 0.5, h = s * 0.15, x = (s - w) / 2
        for (i, y) in [s * 0.52, s * 0.31].enumerated() {
            let r = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: h * 0.3, yRadius: h * 0.3)
            r.lineWidth = max(1, s * 0.035)
            r.stroke()
            NSColor(red: 0.16, green: 0.66, blue: 0.27, alpha: 1).setFill()
            let led = s * 0.035
            NSBezierPath(ovalIn: NSRect(x: x + w - h * 0.6 - led / 2, y: y + h / 2 - led / 2, width: led, height: led)).fill()
            _ = i
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appending(path: name))
        entries.append(#"{ "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(points)x\#(points)", "filename" : "\#(name)" }"#)
    }
}
let json = "{\n  \"images\" : [\n    " + entries.joined(separator: ",\n    ") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! json.write(to: out.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
