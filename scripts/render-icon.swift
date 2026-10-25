// Renders the ATLAS app icon (1024×1024 PNG) following the macOS icon grid:
// an 824-pt continuous-corner squircle centered on a 1024 canvas, with a soft drop shadow.
// Usage: swift scripts/render-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Apple-style squircle (superellipse, n≈5) — closer to the system shape than a plain rounded rect.
func squircle(in r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / n)
        let y = cy + b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(in: body)

// Drop shadow (grid: ~28pt blur, 12pt down)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(shape); ctx.setFillColor(color(0x1B2A6B)); ctx.fillPath()
ctx.restoreGState()

// Background: deep night-blue gradient with a lighter crown
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [color(0x3D6BF2), color(0x2340B8), color(0x141B5C)] as CFArray,
                    locations: [0, 0.45, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let glow = CGGradient(colorsSpace: cs, colors: [color(0x7FA8FF, 0.45), color(0x7FA8FF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 760), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 760), endRadius: 520, options: [])

let center = CGPoint(x: 512, y: 500)
let R: CGFloat = 238

// Orbit (behind the globe): tilted ellipse, faint
func orbitPath() -> CGPath {
    var t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: -0.42)
    return CGPath(ellipseIn: CGRect(x: -360, y: -120, width: 720, height: 240), transform: &t)
}
ctx.addPath(orbitPath())
ctx.setStrokeColor(color(0xFFFFFF, 0.18)); ctx.setLineWidth(10); ctx.strokePath()

// Globe: glassy sphere
ctx.saveGState()
let sphere = CGPath(ellipseIn: CGRect(x: center.x - R, y: center.y - R, width: 2 * R, height: 2 * R), transform: nil)
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x050A30, 0.5))
ctx.addPath(sphere); ctx.setFillColor(color(0x1E3AA8)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(sphere); ctx.clip()
let sphereGrad = CGGradient(colorsSpace: cs, colors: [color(0x9CC4FF), color(0x3E74F0), color(0x1A2E8A)] as CFArray,
                            locations: [0, 0.5, 1])!
ctx.drawRadialGradient(sphereGrad, startCenter: CGPoint(x: center.x - 80, y: center.y + 110), startRadius: 10,
                       endCenter: center, endRadius: R * 1.05, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// Graticule: meridians and parallels
ctx.setStrokeColor(color(0xFFFFFF, 0.55)); ctx.setLineWidth(7)
for w in [0.0, 0.42, 0.78] as [CGFloat] {
    let rw = R * w
    ctx.addEllipse(in: CGRect(x: center.x - rw, y: center.y - R, width: 2 * rw, height: 2 * R))
}
ctx.strokePath()
ctx.move(to: CGPoint(x: center.x, y: center.y - R)); ctx.addLine(to: CGPoint(x: center.x, y: center.y + R))
for lat in [-0.5, 0.0, 0.5] as [CGFloat] {
    let y = center.y + R * lat
    let half = sqrt(max(0, R * R - (y - center.y) * (y - center.y)))
    ctx.move(to: CGPoint(x: center.x - half, y: y)); ctx.addLine(to: CGPoint(x: center.x + half, y: y))
}
ctx.strokePath()
// Specular highlight
let spec = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.55), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(spec, startCenter: CGPoint(x: center.x - 90, y: center.y + 130), startRadius: 0,
                       endCenter: CGPoint(x: center.x - 90, y: center.y + 130), endRadius: 170, options: [])
ctx.restoreGState()
ctx.addPath(sphere); ctx.setStrokeColor(color(0xFFFFFF, 0.9)); ctx.setLineWidth(9); ctx.strokePath()

// Orbit front arc: warm trail sweeping toward the dot (time being tracked)
ctx.saveGState()
var tf = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: -0.42)
let arc = CGMutablePath()
let a: CGFloat = 360, b: CGFloat = 120
let startT: CGFloat = .pi * 1.05, endT: CGFloat = .pi * 1.92
var t = startT
arc.move(to: CGPoint(x: a * cos(t), y: b * sin(t)), transform: tf)
while t < endT { t += 0.01; arc.addLine(to: CGPoint(x: a * cos(t), y: b * sin(t)), transform: tf) }
ctx.addPath(arc)
ctx.setLineWidth(26); ctx.setLineCap(.round)
ctx.replacePathWithStrokedPath(); ctx.clip()
let warm = CGGradient(colorsSpace: cs, colors: [color(0xFF9F0A, 0.0), color(0xFFB340), color(0xFFD60A)] as CFArray,
                      locations: [0, 0.6, 1])!
let p0 = CGPoint(x: a * cos(startT), y: b * sin(startT)).applying(tf)
let p1 = CGPoint(x: a * cos(endT), y: b * sin(endT)).applying(tf)
ctx.drawLinearGradient(warm, start: p0, end: p1, options: [])
ctx.restoreGState()

// The tracking dot, with a halo
let dot = CGPoint(x: a * cos(endT), y: b * sin(endT)).applying(tf)
let halo = CGGradient(colorsSpace: cs, colors: [color(0xFFE38A, 0.85), color(0xFFB340, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(halo, startCenter: dot, startRadius: 0, endCenter: dot, endRadius: 78, options: [])
ctx.addEllipse(in: CGRect(x: dot.x - 30, y: dot.y - 30, width: 60, height: 60))
ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()

// Subtle inner top highlight on the squircle edge
ctx.addPath(shape)
ctx.setStrokeColor(color(0xFFFFFF, 0.12)); ctx.setLineWidth(4); ctx.strokePath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
