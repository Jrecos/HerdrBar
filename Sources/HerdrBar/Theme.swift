import AppKit
import HerdrBarCore
import SwiftUI

enum Phosphor {
    static let canvas = Color(hex: 0x08090A)
    static let panel = Color(hex: 0x16181C)
    static let hover = Color(hex: 0x1B1D22)
    static let selected = Color(hex: 0x22252B)
    static let border = Color(hex: 0x1F2227)
    static let fg = Color(hex: 0xD5D7DC)
    static let dim = Color(hex: 0x5C616B)
    static let muted = Color(hex: 0x9A9FA8)
    static let working = Color(hex: 0xE2B04A)
    static let blocked = Color(hex: 0xEF6B73)
    static let done = Color(hex: 0x6FD39A)
    static let teal = Color(hex: 0x6FC8C8)

    static let blockedNS = NSColor(red: 0xEF / 255, green: 0x6B / 255, blue: 0x73 / 255, alpha: 1)
}

extension Attention {
    var color: Color {
        switch self {
        case .blocked: Phosphor.blocked
        case .done: Phosphor.done
        case .working: Phosphor.working
        case .idle: Phosphor.dim
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255, opacity: 1)
    }
}

enum Mono {
    /// Herdr's own font when installed; otherwise the system monospace (SF Mono, with Menlo behind it).
    static let family: String? = {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return ["JetBrainsMono Nerd Font", "JetBrainsMonoNL Nerd Font"].first(where: installed.contains)
    }()

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        family.map { Font.custom($0, size: size).weight(weight) } ?? .system(size: size, weight: weight, design: .monospaced)
    }

    static func nsFont(_ size: CGFloat) -> NSFont {
        family.flatMap { NSFont(name: $0, size: size) } ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
