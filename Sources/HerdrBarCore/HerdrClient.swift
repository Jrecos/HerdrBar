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
        let core = try await locate(.core)
        let app = try await locate(.app)
        let decoder = JSONDecoder()
        let listing = try decoder.decode(TerminalListing.self, from: try await runner.run(core, ["ls", "--json"]))
        let spaces = try decoder.decode(SpaceListing.self, from: try await runner.run(app, ["ls"])).namesByID
        return try await withThrowingTaskGroup(of: Agent?.self) { group in
            for address in listing.agentAddresses {
                group.addTask {
                    let data = try await runner.run(core, ["get", "--json", address])
                    return try decoder.decode(TerminalDetail.self, from: data).agent(spaces: spaces)
                }
            }
            var agents: [Agent] = []
            for try await agent in group {
                if let agent { agents.append(agent) }
            }
            return agents
        }
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

/// Spawns the CLI off the main thread and kills it after `timeout`.
public struct ProcessRunner: CommandRunner {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 3) {
        self.timeout = timeout
    }

    public func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        let timeout = timeout
        return try await Task.detached(priority: .utility) {
            try Self.runBlocking(executable, arguments, timeout: timeout)
        }.value
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> Data {
        let command = ([executable] + arguments).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CommandFailure(command: command, reason: error.localizedDescription)
        }
        nonisolated(unsafe) var timedOut = false
        let deadline = DispatchWorkItem {
            timedOut = true
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        nonisolated(unsafe) var errorOutput = Data()
        let drained = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: drained) {
            errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        drained.wait()
        deadline.cancel()
        if timedOut {
            throw CommandFailure(command: command, reason: "timed out after \(Int(timeout)) s")
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandFailure(command: command, reason: message.isEmpty ? "exit \(process.terminationStatus)" : message)
        }
        return output
    }
}
