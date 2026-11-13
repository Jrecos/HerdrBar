import Foundation


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
        public let tabs: [Tab]
        public let machine: String?
    }

    public struct Tab: Decodable, Sendable {
        public let terminals: [Terminal]
    }

    public struct Terminal: Decodable, Sendable {
        public let terminal: String
        public let pane: String
        public let status: String?
    }

    public struct InventoryEntry: Sendable {
        public let address: String
        public let space: String
        public let machine: String?
        public let status: String
        public let closeTarget: CloseTarget

        public var attention: Attention {
            switch status {
            case "working": .working
            case "blocked", "error": .blocked
            case "done": .done
            case "idle": .idle
            default: .unknown
            }
        }

        public func agent(detail: TerminalDetail?) -> Agent? {
            let detailStatus = detail?.status?.state
            let sameStatus = (status == "working" && detailStatus == "working")
                || (["blocked", "error"].contains(status) && detailStatus.map { ["blocked", "error"].contains($0) } == true)
            return Agent(address: address, space: space, machine: machine,
                         task: detail.map { TaskTitle.clean($0.title) } ?? "Task unavailable",
                         attention: attention,
                         since: sameStatus ? detail?.statusMs.map { Date(timeIntervalSince1970: $0 / 1000) } : nil,
                         closeTarget: closeTarget)
        }
    }

    public var inventory: [InventoryEntry] {
        spaces.flatMap { space in
            let terminalCount = space.tabs.reduce(0) { $0 + $1.terminals.count }
            return space.tabs.flatMap { tab in
                tab.terminals.compactMap { terminal in
                    terminal.status.map {
                        InventoryEntry(address: terminal.terminal, space: space.name, machine: space.machine, status: $0,
                                       closeTarget: terminalCount == 1 ? .space(space.id) : .pane(terminal.pane))
                    }
                }
            }
        }
    }

    public let spaces: [Space]

}

public enum TaskTitle {
    /// Strips omp's `π`, the braille spinner or `>` marker, and the leading icon glyph.
    public static func clean(_ raw: String?) -> String {
        var title = Substring(raw ?? "")
        if title.first == "π" { title = title.dropFirst().drop(while: \.isWhitespace) }
        if let first = title.first, first == ">" || first.isBrailleSpinner {
            title = title.dropFirst().drop(while: \.isWhitespace)
        }
        if let scalar = title.first?.unicodeScalars.first,
           scalar.properties.generalCategory == .otherSymbol || scalar.properties.generalCategory == .privateUse {
            title = title.dropFirst().drop(while: \.isWhitespace)
        }
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
