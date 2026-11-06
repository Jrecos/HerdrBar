import AppKit
import HerdrBarCore

/// Pre-rendered menu bar images: one per spinner frame, each already holding the glyph and the counts.
/// The status bar re-snapshots its item for every display on each change, so a frame must be a plain bitmap blit.
@MainActor
struct BadgeImages {
    let frames: [NSImage]
    let width: CGFloat

    private static let height: CGFloat = 22
    private static let iconWidth: CGFloat = 18
    private static let textFont = NSFont.menuBarFont(ofSize: 0)

    init(_ badge: StatusBadge, color: NSColor) {
        let text = NSAttributedString(string: badge.text, attributes: [
            .font: Self.textFont,
            .foregroundColor: badge.glyph == .alert ? Phosphor.blockedNS : color,
        ])
        let textWidth = badge.text.isEmpty ? 0 : ceil(text.size().width) + 3
        let width = 2 + Self.iconWidth + textWidth + 2
        self.width = width
        let glyphs: [Character?]
        switch badge.glyph {
        case .working: glyphs = spinnerFrames.map { $0 }
        case .quiet, .unavailable, .alert: glyphs = [nil]
        }
        frames = glyphs.map { glyph in
            Bitmap.render(width: width, height: Self.height) { rect in
                let iconRect = NSRect(x: 2, y: 0, width: Self.iconWidth, height: rect.height)
                switch badge.glyph {
                case .working:
                    let spinner = NSAttributedString(string: String(glyph!), attributes: [.font: Mono.nsFont(15), .foregroundColor: color])
                    Self.drawCentered(spinner, in: iconRect, dy: -1)
                case .quiet, .unavailable:
                    Self.drawSymbol("terminal", size: 13, color: color.withAlphaComponent(badge.glyph == .unavailable ? 0.4 : 1), in: iconRect)
                case .alert:
                    Self.drawSymbol("exclamationmark.triangle.fill", size: 13, color: Phosphor.blockedNS, in: iconRect)
                }
                if textWidth > 0 {
                    let textRect = NSRect(x: iconRect.maxX + 3, y: 0, width: textWidth, height: rect.height)
                    Self.drawCentered(text, in: textRect, dy: 0)
                }
            }
        }
    }

    private static func drawCentered(_ string: NSAttributedString, in rect: NSRect, dy: CGFloat) {
        let size = string.size()
        string.draw(at: NSPoint(x: rect.minX + (rect.width - size.width) / 2, y: rect.minY + (rect.height - size.height) / 2 + dy))
    }

    private static func drawSymbol(_ name: String, size: CGFloat, color: NSColor, in rect: NSRect) {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium)) else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            color.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        let origin = NSPoint(x: rect.minX + (rect.width - tinted.size.width) / 2, y: rect.minY + (rect.height - tinted.size.height) / 2)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

enum Bitmap {
    /// Draws once into a 2x bitmap, so later draws blit instead of re-running a drawing handler.
    static func render(width: CGFloat, height: CGFloat, draw: (NSRect) -> Void) -> NSImage {
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(width * scale)), pixelsHigh: Int(ceil(height * scale)), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
