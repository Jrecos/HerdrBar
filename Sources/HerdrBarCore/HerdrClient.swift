import Foundation

public struct CommandFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public let command: String
    public let reason: String

    public init(command: String, reason: String) {
        self.command = command
        self.reason = reason
    }

    public var description: String { "\(command): \(reason)" }
}

public protocol CommandRunner: Sendable {
    /// Runs `executable` with `arguments`; stdout on success, `CommandFailure` on a non-zero exit, launch failure or timeout.
    func run(_ executable: String, _ arguments: [String]) async throws -> Data
}

public struct HerdrClient: Sendable {
    public let runner: CommandRunner
    public let discovery: CLIDiscovery

    public init(runner: CommandRunner, discovery: CLIDiscovery) {
        self.runner = runner
        self.discovery = discovery
    }

    public func locate(_ tool: Tool) async throws -> String {
        for candidate in discovery.candidates(for: tool) {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if let banner = try? await runner.run(candidate, ["--version"]),
               tool.accepts(version: String(decoding: banner, as: UTF8.self)) {
                return candidate
            }
        }
        throw CommandFailure(command: tool.names[0], reason: "not found; install Herdr.app and its CLI, or defaults write io.github.jrecos.herdrbar \(tool.settingKey) <path>")
    }

    public func snapshot() async -> Snapshot {
        do {
            return .loaded(try await agents())
        } catch let failure as CommandFailure {
            return .unavailable(failure.description)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    public func agents() async throws -> [Agent] {
        let core = try? await locate(.core)
        let app = try await locate(.app)
        let decoder = JSONDecoder()
        let listing = try decoder.decode(SpaceListing.self, from: try await runner.run(app, ["ls"]))
        let inventory = listing.inventory
        var addresses = Set(inventory.map(\.address))
        for entry in inventory {
            addresses.formUnion(entry.subAgents ?? [])
        }
        let details = await withTaskGroup(of: TerminalDetail?.self) { group in
            if let core {
                for address in addresses {
                    group.addTask {
                        guard let data = try? await runner.run(core, ["get", "--json", address]),
                              let detail = try? JSONDecoder().decode(TerminalDetail.self, from: data),
                              detail.address == address else { return nil }
                        return detail
                    }
                }
            }
            var details: [String: TerminalDetail] = [:]
            for await detail in group {
                if let detail { details[detail.address] = detail }
            }
            return details
        }
        return inventory.map { $0.agent(details: details) }
    }

    /// What Herdr's own notification click does: raise the app, then focus the agent's terminal.
    public func focus(_ address: String) async throws {
        let app = try await locate(.app)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let payload = try encoder.encode(["terminal": address])
        _ = try await runner.run(app, ["do", "agent.focus", String(decoding: payload, as: UTF8.self)])
    }
}
