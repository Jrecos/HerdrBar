import Foundation
import Testing
@testable import HerdrBarCore

private let clock = ContinuousClock()

/// A scratch directory the shell scripts receive as `$1` for PID files and markers.
private struct Scratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("herdrbar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path)
    }

    /// Waits up to five seconds for a script to publish a PID into `name`.
    func pid(_ name: String) async -> pid_t? {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}

private func run(_ script: String, in scratch: Scratch, timeout: TimeInterval = 10) async throws -> Data {
    try await ProcessRunner(timeout: timeout).run("/bin/sh", ["-c", script, "sh", scratch.url.path])
}

private func outcome(_ body: () async throws -> Data) async -> Result<Data, any Error> {
    do {
        return .success(try await body())
    } catch {
        return .failure(error)
    }
}

/// True once the kernel no longer knows `pid`. Kills it as a last resort so a failing test cannot leak a process.
private func gone(_ pid: pid_t) async -> Bool {
    for _ in 0..<100 {
        if kill(pid, 0) != 0, errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    kill(pid, SIGKILL)
    return false
}

private extension Result where Success == Data, Failure == any Error {
    var failure: CommandFailure? {
        if case .failure(let error) = self { return error as? CommandFailure }
        return nil
    }

    var isCancellation: Bool {
        if case .failure(let error) = self { return error is CancellationError }
        return false
    }
}

@Suite struct ProcessRunning {
    @Test func returnsCompleteStdoutAndIgnoresStderrOnSuccess() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let data = try await run("printf hello; printf noise >&2", in: scratch)
        #expect(String(decoding: data, as: UTF8.self) == "hello")
    }

    @Test func nonzeroExitReportsTrimmedStderrOrTheStatus() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let spoken = await outcome { try await run("echo '  disk on fire  ' >&2; exit 3", in: scratch) }
        #expect(spoken.failure?.reason == "disk on fire")
        let silent = await outcome { try await run("exit 4", in: scratch) }
        #expect(silent.failure?.reason == "exit 4")
        let verbose = await outcome { try await run("head -c 200000 /dev/zero | tr '\\0' x >&2; exit 1", in: scratch) }
        #expect(verbose.failure?.reason == String(repeating: "x", count: 200_000))
    }

    @Test func missingExecutableIsALaunchFailure() async {
        await #expect(throws: CommandFailure.self) {
            _ = try await ProcessRunner().run("/nonexistent/herdr-app", ["ls"])
        }
    }

    @Test func childReceivesTerminationSignals() async {
        await #expect(throws: CommandFailure.self) {
            _ = try await ProcessRunner().run("/bin/sh", ["-c", "kill -TERM $$; printf survived"])
        }
    }

    @Test func largeConcurrentStdoutAndStderrArriveComplete() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let data = try await run("head -c 1000000 /dev/zero >&2 & head -c 3000000 /dev/zero; wait", in: scratch, timeout: 30)
        #expect(data.count == 3_000_000)
        #expect(data.allSatisfy { $0 == 0 })
    }

    @Test func endlessStdoutStillHitsTheTimeout() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let start = clock.now
        let result = await outcome { try await run("echo $$ > \"$1/pid\"; while :; do echo spam; done", in: scratch, timeout: 1) }
        #expect(result.failure != nil)
        #expect(clock.now - start < .seconds(10))
        let pid = try #require(await scratch.pid("pid"))
        let dead = await gone(pid)
        #expect(dead)
    }

    @Test func termIgnoringChildDiesAtTheTimeoutBeforeTouchingTheMarker() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let script = """
            trap '' TERM
            echo $$ > "$1/pid"
            sleep 2
            : > "$1/marker"
            """
        let start = clock.now
        let result = await outcome { try await run(script, in: scratch, timeout: 1) }
        #expect(result.failure != nil)
        #expect(clock.now - start < .seconds(10))
        let pid = try #require(await scratch.pid("pid"))
        let dead = await gone(pid)
        #expect(dead)
        #expect(!scratch.exists("marker"))
    }

    @Test func cancellationBeforeLaunchNeverStartsTheChild() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await run(": > \"$1/marker\"", in: scratch)
        }
        task.cancel()
        let result = await task.result
        #expect(result.isCancellation)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!scratch.exists("marker"))
    }

    @Test func cancellationMidRunKillsTheChildAndItsDescendants() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let script = """
            (sleep 30; : > "$1/marker") &
            echo $! > "$1/grandchild"
            echo $$ > "$1/pid"
            wait
            """
        let task = Task { try await run(script, in: scratch, timeout: 60) }
        defer { task.cancel() }
        let pid = try #require(await scratch.pid("pid"))
        let grandchild = try #require(await scratch.pid("grandchild"))
        let start = clock.now
        task.cancel()
        let result = await task.result
        #expect(result.isCancellation)
        #expect(clock.now - start < .seconds(5))
        let childDead = await gone(pid)
        let grandchildDead = await gone(grandchild)
        #expect(childDead && grandchildDead)
        #expect(!scratch.exists("marker"))
    }

    @Test func descendantHoldingStdoutCannotDelayTheTimeout() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let script = """
            sleep 30 &
            echo $! > "$1/holder"
            echo partial
            exit 0
            """
        let start = clock.now
        let result = await outcome { try await run(script, in: scratch, timeout: 1) }
        #expect(result.failure != nil)
        #expect(clock.now - start < .seconds(10))
        let holder = try #require(await scratch.pid("holder"))
        let dead = await gone(holder)
        #expect(dead)
    }
}
