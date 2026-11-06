import Foundation

public let spinnerFrames: [Character] = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

/// What the menu bar shows: one glyph and a short count string.
public struct StatusBadge: Sendable, Equatable {
    public enum Glyph: Sendable, Equatable {
        case unavailable
        case quiet
        case working(Character)
        case alert
    }

    public let glyph: Glyph
    public let text: String

    public init(_ snapshot: Snapshot, spinnerFrame: Int = 0) {
        guard case .loaded(let agents) = snapshot else {
            glyph = .unavailable
            text = ""
            return
        }
        let counts = agents.counts
        var parts: [String] = []
        if counts.blocked > 0 { parts.append("!\(counts.blocked)") }
        if counts.working > 0 { parts.append("\(counts.working)") }
        if counts.done > 0 { parts.append("✓\(counts.done)") }
        text = parts.joined(separator: " ")
        if counts.blocked > 0 {
            glyph = .alert
        } else if counts.working > 0 {
            glyph = .working(spinnerFrames[spinnerFrame % spinnerFrames.count])
        } else {
            glyph = .quiet
        }
    }
}
