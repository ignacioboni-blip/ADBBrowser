// Renders the AdbBrowse app icon: gradient squircle, phone outline,
// mini storage-sunburst inside. Usage: swift scripts/make_icon.swift out.png
import AppKit

let S: CGFloat = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background squircle (Apple's ~22.37% corner ratio)
let radius = S * 0.2237
let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                    cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(bgPath)
ctx.clip()

let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.44, green: 0.61, blue: 1.00, alpha: 1),
        CGColor(red: 0.09, green: 0.20, blue: 0.62, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: S / 2, y: S),
                       end: CGPoint(x: S / 2, y: 0),
                       options: [])

// Phone outline
let phoneW: CGFloat = 470, phoneH: CGFloat = 730
let phoneRect = CGRect(x: (S - phoneW) / 2, y: (S - phoneH) / 2, width: phoneW, height: phoneH)
let phonePath = CGPath(roundedRect: phoneRect, cornerWidth: 95, cornerHeight: 95, transform: nil)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.96))
ctx.setLineWidth(36)
ctx.addPath(phonePath)
ctx.strokePath()

// Camera dot
ctx.setFillColor(CGColor(gray: 1, alpha: 0.96))
ctx.fillEllipse(in: CGRect(x: S / 2 - 12, y: phoneRect.maxY - 72, width: 24, height: 24))

// Mini sunburst (two rings of white wedges, fading like the storage map)
let center = CGPoint(x: S / 2, y: S / 2 - 26)
let hole: CGFloat = 66
let band: CGFloat = 62
let gap: CGFloat = 12

struct Wedge {
    let ring: Int
    let from: CGFloat   // degrees, 0 = up, clockwise
    let to: CGFloat
    let alpha: CGFloat
}
let wedges: [Wedge] = [
    Wedge(ring: 0, from: 0, to: 150, alpha: 0.96),
    Wedge(ring: 0, from: 154, to: 250, alpha: 0.66),
    Wedge(ring: 0, from: 254, to: 356, alpha: 0.42),
    Wedge(ring: 1, from: 0, to: 86, alpha: 0.62),
    Wedge(ring: 1, from: 90, to: 150, alpha: 0.40),
    Wedge(ring: 1, from: 154, to: 216, alpha: 0.26),
]

func rad(_ degrees: CGFloat) -> CGFloat {
    (90 - degrees) * .pi / 180   // 0° at 12 o'clock, clockwise
}

for w in wedges {
    let rIn = hole + CGFloat(w.ring) * (band + gap)
    let rOut = rIn + band
    let path = CGMutablePath()
    path.addArc(center: center, radius: rOut,
                startAngle: rad(w.from), endAngle: rad(w.to), clockwise: true)
    path.addArc(center: center, radius: rIn,
                startAngle: rad(w.to), endAngle: rad(w.from), clockwise: false)
    path.closeSubpath()
    ctx.setFillColor(CGColor(gray: 1, alpha: w.alpha))
    ctx.addPath(path)
    ctx.fillPath()
}

NSGraphicsContext.restoreGraphicsState()

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
