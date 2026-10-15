// Generuje ikonę MacCare AI (PNG 1024×1024): grafitowy kwadrat z pierścieniem „kondycji” i linią pulsu.
// Własny motyw – nie nawiązuje do ikon Strażnika ani CleanMyMac. Użycie: swift make_icon.swift <wyjście.png>
import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}

// Tło: zaokrąglony kwadrat z pionowym gradientem.
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 196, cornerHeight: 196, transform: nil))
ctx.clip()
let grad = CGGradient(colorsSpace: space, colors: [rgb(0x12323B), rgb(0x0A161C)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
// delikatna poświata u góry
let glow = CGGradient(colorsSpace: space, colors: [rgb(0x3CCBC0, 0.22), rgb(0x3CCBC0, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 800), startRadius: 0, endCenter: CGPoint(x: 512, y: 800), endRadius: 520, options: [])
ctx.restoreGState()

// Pierścień: tor + łuk 270°.
let c = CGPoint(x: 512, y: 512), r: CGFloat = 262
ctx.setLineCap(.round)
ctx.setLineWidth(72)
ctx.setStrokeColor(rgb(0x2A5B61, 0.55))
ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false); ctx.strokePath()
ctx.setStrokeColor(rgb(0x3CCBC0))
let start = CGFloat.pi / 2, sweep = CGFloat.pi * 1.5
ctx.addArc(center: c, radius: r, startAngle: start, endAngle: start - sweep, clockwise: true); ctx.strokePath()

// Bursztynowa kropka na końcu łuku (sygnał „uwaga/pomiar”).
let endAngle = start - sweep
let dot = CGPoint(x: c.x + r * cos(endAngle), y: c.y + r * sin(endAngle))
ctx.setFillColor(rgb(0xF6B94A)); ctx.fillEllipse(in: CGRect(x: dot.x - 30, y: dot.y - 30, width: 60, height: 60))

// Linia pulsu w środku.
ctx.setStrokeColor(rgb(0xE9F7F5)); ctx.setLineWidth(38); ctx.setLineJoin(.round)
ctx.beginPath()
ctx.move(to: CGPoint(x: 330, y: 506))
ctx.addLine(to: CGPoint(x: 428, y: 506))
ctx.addLine(to: CGPoint(x: 470, y: 604))
ctx.addLine(to: CGPoint(x: 536, y: 410))
ctx.addLine(to: CGPoint(x: 584, y: 506))
ctx.addLine(to: CGPoint(x: 694, y: 506))
ctx.strokePath()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
