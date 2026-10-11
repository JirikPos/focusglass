#!/usr/bin/env swift
// Vykreslí ikonu FocusGlass (1024 px) a uloží ji jako PNG.
//   swift scripts/make-icon.swift <výstup.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Mřížka ikon macOS: tělo 824 px uprostřed plátna 1024 px.
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Stín
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill()
shape.fill()
ctx.restoreGState()

// Pozadí: matně černé sklo (nahoře o kousek světlejší)
ctx.saveGState()
shape.addClip()
NSGradient(colors: [
    NSColor(white: 0.17, alpha: 1),
    NSColor(white: 0.07, alpha: 1),
    NSColor(white: 0.03, alpha: 1),
])!.draw(in: body, angle: -90)

// Skleněný odlesk v horní polovině
let gloss = NSBezierPath(ovalIn: CGRect(x: body.minX - 160, y: body.midY - 40, width: body.width + 320, height: body.height))
NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0.0)])!
    .draw(in: gloss, angle: -90)
ctx.restoreGState()

// Jemný světlý okraj
NSColor.white.withAlphaComponent(0.22).setStroke()
let rim = NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
rim.lineWidth = 6
rim.stroke()

let center = CGPoint(x: size / 2, y: size / 2)
let ringRadius: CGFloat = 270

// Stopa prstence
let track = NSBezierPath()
track.appendArc(withCenter: center, radius: ringRadius, startAngle: 0, endAngle: 360)
track.lineWidth = 30
NSColor.white.withAlphaComponent(0.10).setStroke()
track.stroke()

// Průběh časovače (3/4) se zářením
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 34, color: NSColor.white.withAlphaComponent(0.6).cgColor)
let progress = NSBezierPath()
progress.appendArc(withCenter: center, radius: ringRadius, startAngle: 90, endAngle: -180, clockwise: true)
progress.lineWidth = 30
progress.lineCapStyle = .round
NSColor.white.setStroke()
progress.stroke()
ctx.restoreGState()

// Oko uprostřed (SF Symbol)
let config = NSImage.SymbolConfiguration(pointSize: 230, weight: .light)
    .applying(.init(paletteColors: [.white]))
if let eye = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = eye.size
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    eye.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
    ctx.restoreGState()
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("✓ \(output)")
