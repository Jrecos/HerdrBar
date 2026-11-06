import AppKit

let canvas = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196)
NSColor(srgbRed: 0.035, green: 0.065, blue: 0.045, alpha: 1).setFill()
background.fill()
NSColor(srgbRed: 0.16, green: 0.28, blue: 0.19, alpha: 1).setStroke()
background.lineWidth = 3
background.stroke()
let phosphor = NSColor(srgbRed: 0.53, green: 0.96, blue: 0.53, alpha: 1)
phosphor.setStroke()
let prompt = NSBezierPath()
prompt.lineWidth = 42
prompt.lineCapStyle = .round
prompt.lineJoinStyle = .round
prompt.move(to: NSPoint(x: 288, y: 620))
prompt.line(to: NSPoint(x: 420, y: 512))
prompt.line(to: NSPoint(x: 288, y: 404))
prompt.move(to: NSPoint(x: 510, y: 404))
prompt.line(to: NSPoint(x: 686, y: 404))
prompt.stroke()
let dots: [(CGFloat, CGFloat, CGFloat)] = [
    (728, 722, 0.22), (728, 682, 0.35), (728, 642, 0.5),
    (768, 722, 1), (768, 682, 0.8), (768, 642, 0.65)
]
for (x, y, alpha) in dots {
    phosphor.withAlphaComponent(alpha).setFill()
    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 18, height: 18)).fill()
}
NSGraphicsContext.restoreGraphicsState()
let png = canvas.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
