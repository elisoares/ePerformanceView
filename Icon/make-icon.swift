// Draws the app icon (option J: big "e" on a chip, Activity Monitor-like screen) at 1024 px.
// Coordinates follow the approved 100-unit mockup; the body is scaled to Apple's 824 px icon grid.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1)          // y down, like the SVG mockup
let s: CGFloat = 824 / 92
ctx.translateBy(x: (size - 824) / 2 - 4 * s, y: (size - 824) / 2 - 4 * s + 10)
ctx.scaleBy(x: s, y: s)

// Bezel with a soft drop shadow.
let body = CGPath(roundedRect: CGRect(x: 4, y: 4, width: 92, height: 92), cornerWidth: 22, cornerHeight: 22, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 1.2), blur: 3, color: rgb(0x000000, 0.35))
ctx.addPath(body); ctx.setFillColor(rgb(0x9AA1A9)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(body); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xF4F6F8), rgb(0xB9C0C8), rgb(0x7D858E)], [0, 0.5, 1]),
                       start: CGPoint(x: 0, y: 4), end: CGPoint(x: 0, y: 96), options: [])
ctx.restoreGState()

// Dark screen with a fine grid.
let screen = CGPath(roundedRect: CGRect(x: 11, y: 11, width: 78, height: 78), cornerWidth: 16, cornerHeight: 16, transform: nil)
ctx.saveGState(); ctx.addPath(screen); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x1A2A22), rgb(0x050B08)], [0, 1]),
                       start: CGPoint(x: 0, y: 11), end: CGPoint(x: 0, y: 89), options: [])
ctx.setStrokeColor(rgb(0x1F5A3A)); ctx.setLineWidth(0.6)
var g: CGFloat = 10
while g < 100 {
    ctx.move(to: CGPoint(x: g, y: 0)); ctx.addLine(to: CGPoint(x: g, y: 100))
    ctx.move(to: CGPoint(x: 0, y: g)); ctx.addLine(to: CGPoint(x: 100, y: g))
    g += 10
}
ctx.strokePath()
ctx.restoreGState()

// Chip: package outline and pins.
ctx.setStrokeColor(rgb(0x2E7D4A)); ctx.setLineWidth(3); ctx.setLineCap(.round)
for p: CGFloat in [38, 50, 62] {
    ctx.move(to: CGPoint(x: p, y: 17)); ctx.addLine(to: CGPoint(x: p, y: 24))
    ctx.move(to: CGPoint(x: p, y: 76)); ctx.addLine(to: CGPoint(x: p, y: 83))
    ctx.move(to: CGPoint(x: 17, y: p)); ctx.addLine(to: CGPoint(x: 24, y: p))
    ctx.move(to: CGPoint(x: 76, y: p)); ctx.addLine(to: CGPoint(x: 83, y: p))
}
ctx.strokePath()
ctx.addPath(CGPath(roundedRect: CGRect(x: 25, y: 25, width: 50, height: 50), cornerWidth: 9, cornerHeight: 9, transform: nil))
ctx.strokePath()

// The "e": crossbar, then the bowl going over the top and around to the lower right.
let e = CGMutablePath()
e.move(to: CGPoint(x: 36, y: 51)); e.addLine(to: CGPoint(x: 64, y: 51))
e.addArc(center: CGPoint(x: 50, y: 51), radius: 14, startAngle: 0, endAngle: .pi / 4, clockwise: true)
ctx.saveGState()
ctx.addPath(e); ctx.setLineWidth(6.5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x3CF0C8), rgb(0x34F56A)], [0, 1]),
                       start: CGPoint(x: 34, y: 35), end: CGPoint(x: 66, y: 67), options: [])
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
