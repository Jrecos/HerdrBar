import Foundation

/// Agents for snapshot mode and tests. Ages are relative so a fixture renders the same on any day.
public struct Fixture: Decodable, Sendable {
    public struct Row: Decodable, Sendable {
        public let address: String
        public let space: String
        public let machine: String?
        public let task: String
        public let attention: Attention
        public let ageMinutes: Double
        public let runningSubagentCount: Int?

        enum CodingKeys: String, CodingKey {
            case address, space, machine, task, attention
            case ageMinutes = "age_minutes"
            case runningSubagentCount = "running_subagent_count"
        }
    }

    public let agents: [Row]

    public static func load(_ url: URL, now: Date = Date()) throws -> [Agent] {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).agents(now: now)
    }

    public func agents(now: Date) -> [Agent] {
        agents.map {
            Agent(
                address: $0.address, space: $0.space, machine: $0.machine, task: $0.task,
                attention: $0.attention, since: now.addingTimeInterval(-$0.ageMinutes * 60),
                runningSubagentCount: $0.runningSubagentCount)
        }
    }
}
