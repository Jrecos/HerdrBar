import AppKit
import SwiftUI
import HerdrBarCore

/// One braille cell animated by Core Animation, so a spinning row costs the process nothing per frame.
struct SpinnerGlyph: NSViewRepresentable {
    let color: NSColor
    let font: NSFont

    @MainActor private static var cache: [String: (frames: [CGImage], size: NSSize)] = [:]

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let (frames, size) = Self.frames(color: color, font: font)
        view.frame = NSRect(origin: .zero, size: size)
        let glyph = CALayer()
        glyph.frame = view.bounds
        glyph.contentsScale = 2
        glyph.contentsGravity = .center
        glyph.contents = frames.first
        let spin = CAKeyframeAnimation(keyPath: "contents")
        spin.values = frames
        spin.calculationMode = .discrete
        spin.duration = Double(frames.count) / 10
        spin.repeatCount = .infinity
        glyph.add(spin, forKey: "spin")
        view.layer?.addSublayer(glyph)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        Self.frames(color: color, font: font).size
    }

    @MainActor private static func frames(color: NSColor, font: NSFont) -> (frames: [CGImage], size: NSSize) {
        let key = "\(font.fontName)/\(font.pointSize)/\(color)"
        if let cached = cache[key] { return cached }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = NSAttributedString(string: "⠿", attributes: attributes).size()
        let cell = NSSize(width: ceil(size.width), height: ceil(size.height))
        let frames = spinnerFrames.map { character in
            Bitmap.render(width: cell.width, height: cell.height) { _ in
                NSAttributedString(string: String(character), attributes: attributes).draw(at: .zero)
            }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        }
        cache[key] = (frames, cell)
        return (frames, cell)
    }
}
