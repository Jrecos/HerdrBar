import Foundation

/// Declaration order is the display order.
public enum Attention: String, CaseIterable, Codable, Sendable {
    case blocked, done, working, idle, unknown

    public var groupLabel: String {
        self == .working ? "running" : rawValue
    }

    public var tag: String {
        switch self {
        case .blocked: "[!!]"
        case .done: "[ok]"
        case .working: "[⠋]"
        case .idle: "[--]"
        case .unknown: "[?]"
        }
    }
}

public struct Agent: Identifiable, Sendable, Codable, Equatable {
    public let address: String
    public let space: String
    public let machine: String?
    public let task: String
    public let attention: Attention
    public let since: Date?

    public var id: String { address }

    public init(address: String, space: String, machine: String?, task: String, attention: Attention, since: Date?) {
        self.address = address
        self.space = space
        self.machine = machine
        self.task = task
        self.attention = attention
        self.since = since
    }

    public func age(at now: Date) -> String {
        guard let since else { return "age unavailable" }
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }
}

public enum Snapshot: Sendable, Equatable {
    case loaded([Agent])
    case unavailable(String)

    public var agents: [Agent] {
        if case .loaded(let agents) = self { return agents }
        return []
    }

    public var failure: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

public struct AgentGroup: Sendable, Equatable, Identifiable {
    public let attention: Attention
    public let agents: [Agent]
    public var id: Attention { attention }
}

public struct Counts: Sendable, Equatable {
    public var blocked = 0
    public var done = 0
    public var working = 0
    public var idle = 0

    public init(blocked: Int = 0, done: Int = 0, working: Int = 0, idle: Int = 0) {
        self.blocked = blocked
        self.done = done
        self.working = working
        self.idle = idle
    }
}

extension Array where Element == Agent {
    /// Non-empty groups in `Attention` order; rows sorted by space, then address, so the list is stable between refreshes.
    public func grouped() -> [AgentGroup] {
        Attention.allCases.compactMap { attention in
            let rows = filter { $0.attention == attention }.sorted {
                let order = $0.space.localizedCaseInsensitiveCompare($1.space)
                return order == .orderedSame ? $0.address < $1.address : order == .orderedAscending
            }
            return rows.isEmpty ? nil : AgentGroup(attention: attention, agents: rows)
        }
    }

    public func ordered() -> [Agent] {
        grouped().flatMap(\.agents)
    }

    public var counts: Counts {
        reduce(into: Counts()) { counts, agent in
            switch agent.attention {
            case .blocked: counts.blocked += 1
            case .done: counts.done += 1
            case .working: counts.working += 1
            case .idle: counts.idle += 1
            case .unknown: break
            }
        }
    }
}

/// Which addresses changed attention since the previous snapshot, for the row flash.
public struct AttentionTracker: Sendable, Equatable {
    public private(set) var previous: [String: Attention] = [:]

    public init() {}

    public mutating func record(_ agents: [Agent]) -> Set<String> {
        let current = Dictionary(uniqueKeysWithValues: agents.map { ($0.address, $0.attention) })
        let changed = Set(current.filter { address, attention in
            previous[address].map { $0 != attention } ?? false
        }.keys)
        previous = current
        return changed
    }
}
