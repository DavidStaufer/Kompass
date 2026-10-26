// Erzeugt das App-Icon (1024×1024 PNG) im macOS-Icon-Raster.
// Aufruf: swift Scripts/make_icon.swift <ausgabe.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
// --ios: randlos und ohne Transparenz (iOS rundet die Ecken selbst ab)
let ios = CommandLine.arguments.contains("--ios")
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Squircle 824×824 mit Schatten (Apple-Raster: 100 px Rand)
let rect = ios ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = ios ? 0 : 185
let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
if !ios { ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.32).cgColor) }
ctx.addPath(shape)
ctx.setFillColor(NSColor(red: 0.22, green: 0.24, blue: 0.66, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

// Verlauf
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let space = CGColorSpaceCreateDeviceRGB()
let grad = CGGradient(colorsSpace: space, colors: [
    NSColor(red: 0.42, green: 0.50, blue: 1.00, alpha: 1).cgColor,
    NSColor(red: 0.30, green: 0.33, blue: 0.86, alpha: 1).cgColor,
    NSColor(red: 0.17, green: 0.18, blue: 0.52, alpha: 1).cgColor
] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: rect.maxY), end: CGPoint(x: 512, y: rect.minY), options: [])
// Glanzkante oben (Licht auf dem Material)
let shine = CGGradient(colorsSpace: space, colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 700), options: [])
ctx.restoreGState()

let center = CGPoint(x: 512, y: 512)

// Ring mit Teilstrichen
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.30).cgColor)
ctx.setLineWidth(14)
ctx.strokeEllipse(in: CGRect(x: center.x - 290, y: center.y - 290, width: 580, height: 580))
for i in 0..<48 {
    let a = CGFloat(i) / 48 * 2 * .pi
    let major = i % 12 == 0
    let r1: CGFloat = major ? 228 : 252
    let r2: CGFloat = 270
    ctx.setLineWidth(major ? 12 : 5)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(major ? 0.85 : 0.35).cgColor)
    ctx.move(to: CGPoint(x: center.x + cos(a) * r1, y: center.y + sin(a) * r1))
    ctx.addLine(to: CGPoint(x: center.x + cos(a) * r2, y: center.y + sin(a) * r2))
    ctx.strokePath()
}

// Nadel (35° gedreht)
ctx.saveGState()
ctx.translateBy(x: center.x, y: center.y)
ctx.rotate(by: -35 * .pi / 180)
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.3).cgColor)
let w: CGFloat = 92, h: CGFloat = 300
// Nord (weiß)
ctx.move(to: CGPoint(x: -w, y: 0)); ctx.addLine(to: CGPoint(x: 0, y: h)); ctx.addLine(to: CGPoint(x: w, y: 0)); ctx.closePath()
ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
// Süd (Korall-Akzent)
ctx.move(to: CGPoint(x: -w, y: 0)); ctx.addLine(to: CGPoint(x: 0, y: -h)); ctx.addLine(to: CGPoint(x: w, y: 0)); ctx.closePath()
ctx.setFillColor(NSColor(red: 1.0, green: 0.48, blue: 0.42, alpha: 1).cgColor); ctx.fillPath()
ctx.restoreGState()
// Mitte
ctx.setFillColor(NSColor(red: 0.20, green: 0.21, blue: 0.58, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60))
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillEllipse(in: CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Icon geschrieben: \(out)")
