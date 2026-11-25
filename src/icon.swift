// Рисует иконку Lumen (1024×1024, сетка macOS: плашка 824 с отступом 100).
// Солнце над горизонтом светит сильнее своего отражения: «ярче белого» против обычного.
// usage: swift icon.swift out.png
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
func grad(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

// плашка
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

// тень под плашкой
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0, 0, 0, 0.45))
ctx.addPath(platePath); ctx.setFillColor(c(0.05, 0.04, 0.08)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(platePath); ctx.clip()

// небо: от глубокого фиолетового сверху к тёплому у горизонта
let horizon: CGFloat = 400
ctx.drawLinearGradient(grad([(0, c(0.33, 0.16, 0.42)), (0.55, c(0.12, 0.06, 0.22)), (1, c(0.04, 0.03, 0.09))]),
                       start: CGPoint(x: 512, y: horizon), end: CGPoint(x: 512, y: 924), options: [])
// вода
ctx.drawLinearGradient(grad([(0, c(0.10, 0.05, 0.16)), (1, c(0.02, 0.02, 0.05))]),
                       start: CGPoint(x: 512, y: horizon), end: CGPoint(x: 512, y: 100), options: [])

let sun = CGPoint(x: 512, y: 590)
let R: CGFloat = 150

// ореол над горизонтом
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: horizon, width: S, height: S))
ctx.drawRadialGradient(grad([(0, c(1.0, 0.80, 0.55, 0.95)), (0.35, c(0.95, 0.45, 0.85, 0.55)), (0.7, c(0.55, 0.25, 0.95, 0.18)), (1, c(0.4, 0.2, 0.8, 0))]),
                       startCenter: sun, startRadius: R * 0.8, endCenter: sun, endRadius: R * 3.2, options: [])
// диск — почти белый, горячий центр
ctx.drawRadialGradient(grad([(0, c(1, 1, 1)), (0.55, c(1, 0.98, 0.92)), (0.85, c(1, 0.86, 0.66)), (1, c(1, 0.72, 0.55))]),
                       startCenter: sun, startRadius: 0, endCenter: sun, endRadius: R, options: [])
ctx.restoreGState()

// отражение — то же солнце, но тусклое и в полосах
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: 100, width: S, height: horizon - 100))
let refl = CGPoint(x: 512, y: 2 * horizon - sun.y)
for i in 0..<9 {
    let y = horizon - 14 - CGFloat(i) * 30
    let w = (R * 1.7) * (1 - CGFloat(i) * 0.085)
    let a = 0.62 * (1 - CGFloat(i) * 0.1)
    let band = CGRect(x: refl.x - w, y: y - 9, width: w * 2, height: 13)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: band, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)); ctx.clip()
    ctx.drawLinearGradient(grad([(0, c(0.75, 0.45, 0.95, 0)), (0.5, c(1, 0.82, 0.7, a)), (1, c(0.75, 0.45, 0.95, 0))]),
                           start: CGPoint(x: band.minX, y: y), end: CGPoint(x: band.maxX, y: y), options: [])
    ctx.restoreGState()
}
ctx.restoreGState()

// линия горизонта — тонкий свет
ctx.saveGState()
ctx.clip(to: CGRect(x: 100, y: horizon - 2, width: 824, height: 4))
ctx.drawLinearGradient(grad([(0, c(1, 0.8, 0.9, 0)), (0.5, c(1, 0.9, 0.85, 0.85)), (1, c(1, 0.8, 0.9, 0))]),
                       start: CGPoint(x: 140, y: horizon), end: CGPoint(x: 884, y: horizon), options: [])
ctx.restoreGState()
ctx.restoreGState()

// стеклянная кромка
ctx.addPath(platePath)
ctx.setStrokeColor(c(1, 1, 1, 0.10)); ctx.setLineWidth(3); ctx.strokePath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
