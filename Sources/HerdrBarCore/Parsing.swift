import Foundation

/// `hc ls --json`
public struct TerminalListing: Decodable, Sendable {
    public struct Entry: Decodable, Sendable {
        public let address: String
        public let status: String?
    }

    public let terminals: [Entry]

    /// Only terminals whose program reports a status are agents.
    public var agentAddresses: [String] {
        terminals.filter { $0.status != nil }.map(\.address)
    }
}

/// `hc get --json <address>`
public struct TerminalDetail: Decodable, Sendable {
    public struct Status: Decodable, Sendable {
        public let state: String
    }

    public let address: String
    public let parent: String?
    public let state: String
    public let status: Status?
    public let turn: Int?
    public let labels: [String: String]?
    public let title: String?
    public let statusMs: Double?

    enum CodingKeys: String, CodingKey {
        case address, parent, state, status, turn, labels, title
        case statusMs = "status_ms"
    }
}

/// `herdr-app ls`
public struct SpaceListing: Decodable, Sendable {
    public struct Space: Decodable, Sendable {
        public let id: String
        public let name: String
    }

    public let spaces: [Space]

    public var namesByID: [String: String] {
        Dictionary(spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

public enum TaskTitle {
    /// Strips omp's `π`, the braille spinner or `>` marker, and the leading icon glyph.
    public static func clean(_ raw: String?) -> String {
        var title = Substring(raw ?? "")
        if title.first == "π" { title = title.dropFirst().drop(while: \.isWhitespace) }
        if let first = title.first, first == ">" || first.isBrailleSpinner {
            title = title.dropFirst().drop(while: \.isWhitespace)
        }
        title = title.drop { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }.drop(while: \.isWhitespace)
        let collapsed = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? "Untitled agent" : collapsed
    }
}

extension Character {
    var isBrailleSpinner: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return (0x2800...0x28FF).contains(scalar.value)
    }
}

extension TerminalDetail {
    /// Core keeps `done` after the user looked; Herdr derives attention from `turn` vs `herdr.seen`.
    public var attention: Attention? {
        guard let raw = status?.state else { return nil }
        let labels = labels ?? [:]
        switch raw {
        case "working": return .working
        case "blocked", "error": return .blocked
        case "idle", "done":
            let seen = Int(labels["herdr.seen"] ?? "") ?? 0
            return (turn ?? 0) > seen ? .done : .idle
        default: return nil
        }
    }

    public var machine: String? {
        guard let slash = address.firstIndex(of: "/") else { return nil }
        return String(address[..<slash])
    }

    /// `nil` for sub-agents, dead terminals, and terminals without an agent status.
    public func agent(spaces: [String: String]) -> Agent? {
        guard parent == nil, state == "live", let attention else { return nil }
        let spaceID = labels?["herdr.space"] ?? ""
        let qualified = machine.map { "\($0)/\(spaceID)" } ?? spaceID
        let space = spaces[qualified] ?? (spaceID.isEmpty ? "Unassigned" : spaceID)
        return Agent(
            address: address,
            space: space,
            machine: machine,
            task: TaskTitle.clean(title),
            attention: attention,
            since: Date(timeIntervalSince1970: (statusMs ?? 0) / 1000))
    }
}
