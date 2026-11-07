import Darwin.crt_externs
import Foundation

/// Runs a CLI in its own process group. Timeout and cancellation send SIGKILL to that group
/// and return without waiting for pipe EOF or process exit.
public struct ProcessRunner: CommandRunner {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 3) {
        self.timeout = timeout
    }

    public func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        try Task.checkCancellation()
        let invocation = Invocation(executable: executable, arguments: arguments, timeout: timeout)
        let cancellation = CancellationRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    invocation.run(cancellation: cancellation) { continuation.resume(with: $0) }
                }
            }
        } onCancel: {
            cancellation.request()
        }
    }
}

/// The only state shared between the calling task and the worker.
private final class CancellationRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func request() {
        lock.withLock { requested = true }
    }

    var isRequested: Bool {
        lock.withLock { requested }
    }
}

private struct Invocation: Sendable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval

    func failure(_ reason: String) -> CommandFailure {
        CommandFailure(command: ([executable] + arguments).joined(separator: " "), reason: reason)
    }

    /// The whole worker: spawn, drain, decide, resume exactly once, then reap whatever is left.
    func run(cancellation: CancellationRequest, resume: (Result<Data, any Error>) -> Void) {
        guard !cancellation.isRequested else { return resume(.failure(CancellationError())) }
        let worker: Worker
        do {
            worker = try Worker(self, cancellation: cancellation, deadline: ContinuousClock.now + .seconds(timeout))
        } catch {
            return resume(.failure(error))
        }
        let outcome = worker.drain()
        worker.reap(blocking: false)
        resume(outcome)
        worker.reap(blocking: true)
    }
}

private enum ChildExit {
    case exited(Int32)
    case signalled(Int32)
}

/// Signalling is only legal while the child is unreaped; reaping frees its PID and group ID for reuse.
private enum Child {
    case unreaped(pid_t, exit: ChildExit?)
    case reaped
}

private struct Stream {
    var reader: Int32?
    var bytes = Data()

    /// Reads at most one buffer so a flooding stream cannot starve the other one or the clock. EOF closes the reader.
    mutating func readChunk(into buffer: inout [UInt8]) -> Int32? {
        guard let fd = reader else { return nil }
        let count: Int = buffer.withUnsafeMutableBytes { raw -> Int in
            let count = read(fd, raw.baseAddress, raw.count)
            if count > 0 { bytes.append(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: count) }
            return count
        }
        if count > 0 { return nil }
        if count == 0 {
            closeReader()
            return nil
        }
        switch errno {
        case EAGAIN, EINTR: return nil
        default: return errno
        }
    }

    mutating func closeReader() {
        if let fd = reader { close(fd) }
        reader = nil
    }
}

/// Owns the child, both pipe readers and the output buffers; nothing else touches them.
private final class Worker {
    private let invocation: Invocation
    private let cancellation: CancellationRequest
    private let deadline: ContinuousClock.Instant
    private var child: Child
    private var stdout: Stream
    private var stderr: Stream
    private var buffer = [UInt8](repeating: 0, count: 1 << 16)
    private var polls = [pollfd](repeating: pollfd(), count: 2)

    init(_ invocation: Invocation, cancellation: CancellationRequest, deadline: ContinuousClock.Instant) throws {
        self.invocation = invocation
        self.cancellation = cancellation
        self.deadline = deadline
        let out = try makePipe(invocation)
        let err: (reader: Int32, writer: Int32)
        do {
            err = try makePipe(invocation)
        } catch {
            close(out.reader)
            close(out.writer)
            throw error
        }
        defer {
            close(out.writer)
            close(err.writer)
        }
        stdout = Stream(reader: out.reader)
        stderr = Stream(reader: err.reader)
        do {
            if cancellation.isRequested { throw CancellationError() }
            child = .unreaped(try spawn(invocation, stdout: out.writer, stderr: err.writer), exit: nil)
        } catch {
            close(out.reader)
            close(err.reader)
            throw error
        }
    }

    /// Runs until the child has exited and both streams hit EOF, or until cancellation, the deadline or an I/O error wins.
    func drain() -> Result<Data, any Error> {
        while true {
            if cancellation.isRequested { return .failure(stop(CancellationError())) }
            if ContinuousClock.now >= deadline {
                return .failure(stop(invocation.failure("timed out after \(Int(invocation.timeout)) s")))
            }
            if let failure = observeExit() { return .failure(stop(failure)) }
            if case .unreaped(_, let exit?) = child, stdout.reader == nil, stderr.reader == nil {
                return result(for: exit)
            }
            if let failure = pump() { return .failure(stop(failure)) }
        }
    }

    /// Reaps the direct child. Blocking is only requested after the caller already holds its result.
    func reap(blocking: Bool) {
        guard case .unreaped(let pid, _) = child else { return }
        var status: Int32 = 0
        while true {
            let reaped = waitpid(pid, &status, blocking ? 0 : WNOHANG)
            if reaped == 0 { return }
            if reaped == pid || errno != EINTR {
                child = .reaped
                return
            }
        }
    }

    /// Notes the child's exit without reaping it, so its PID and group stay reserved while signalling may still happen.
    /// Only ECHILD means ownership is gone; any other failure leaves the child ours to kill and reap.
    private func observeExit() -> CommandFailure? {
        guard case .unreaped(let pid, .none) = child else { return nil }
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
            switch errno {
            case EINTR: continue
            case ECHILD:
                child = .reaped
                return invocation.failure("lost track of the child process")
            default: return invocation.failure("waitid failed (\(errno))")
            }
        }
        guard info.si_pid == pid else { return nil }
        child = .unreaped(pid, exit: info.si_code == CLD_EXITED ? .exited(info.si_status) : .signalled(info.si_status))
        return nil
    }

    /// One bounded round: wait at most 25 ms (or until the deadline) for either pipe, then read one chunk from each ready one.
    private func pump() -> CommandFailure? {
        var count = 0
        if let fd = stdout.reader {
            polls[count] = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            count += 1
        }
        if let fd = stderr.reader {
            polls[count] = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            count += 1
        }
        let wait = Int32(max(0, min(25, (deadline - ContinuousClock.now) / .milliseconds(1))))
        if poll(&polls, nfds_t(count), wait) < 0, errno != EINTR, errno != EAGAIN {
            return invocation.failure("poll failed (\(errno))")
        }
        for index in 0..<count where polls[index].revents != 0 {
            let code = polls[index].fd == stdout.reader ? stdout.readChunk(into: &buffer) : stderr.readChunk(into: &buffer)
            if let code { return invocation.failure("read failed (\(code))") }
        }
        return nil
    }

    private func stop<Failure: Error>(_ failure: Failure) -> Failure {
        if case .unreaped(let pid, _) = child {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        stdout.closeReader()
        stderr.closeReader()
        return failure
    }

    private func result(for exit: ChildExit) -> Result<Data, any Error> {
        if case .exited(0) = exit { return .success(stdout.bytes) }
        let message = String(decoding: stderr.bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch exit {
        case .exited(let code): return .failure(invocation.failure(message.isEmpty ? "exit \(code)" : message))
        case .signalled(let signal): return .failure(invocation.failure(message.isEmpty ? "signal \(signal)" : message))
        }
    }
}

/// A pipe whose descriptors sit above 0-2 so they cannot collide with the child's standard descriptor actions,
/// close on exec, and whose read end never blocks.
private func makePipe(_ invocation: Invocation) throws -> (reader: Int32, writer: Int32) {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { throw invocation.failure("pipe failed (\(errno))") }
    func fail(_ step: String) -> CommandFailure {
        let failure = invocation.failure("\(step) failed (\(errno))")
        for fd in fds where fd >= 0 { close(fd) }
        return failure
    }
    for index in fds.indices where fds[index] <= STDERR_FILENO {
        let raised = fcntl(fds[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        close(fds[index])
        fds[index] = raised
        if raised < 0 { throw fail("dup") }
    }
    for fd in fds where fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 { throw fail("cloexec") }
    let flags = fcntl(fds[0], F_GETFL)
    if flags < 0 || fcntl(fds[0], F_SETFL, flags | O_NONBLOCK) < 0 { throw fail("nonblock") }
    return (fds[0], fds[1])
}

/// Spawns with stdin on /dev/null, the pipes as stdout/stderr, no other inherited descriptors, the parent's
/// environment, and a process group of its own that exists before any child code runs.
private func spawn(_ invocation: Invocation, stdout: Int32, stderr: Int32) throws -> pid_t {
    func require(_ status: Int32, _ step: String) throws {
        guard status == 0 else { throw invocation.failure("\(step) failed (\(String(cString: strerror(status))))") }
    }
    var actions: posix_spawn_file_actions_t? = nil
    try require(posix_spawn_file_actions_init(&actions), "spawn actions")
    defer { posix_spawn_file_actions_destroy(&actions) }
    try require(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0), "stdin action")
    try require(posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO), "stdout action")
    try require(posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO), "stderr action")

    var attributes: posix_spawnattr_t? = nil
    try require(posix_spawnattr_init(&attributes), "spawn attributes")
    defer { posix_spawnattr_destroy(&attributes) }
    let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
    try require(posix_spawnattr_setflags(&attributes, Int16(flags)), "spawn flags")
    try require(posix_spawnattr_setpgroup(&attributes, 0), "process group")
    var mask = sigset_t()
    sigemptyset(&mask)
    try require(posix_spawnattr_setsigmask(&attributes, &mask), "signal mask")
    var defaults = sigset_t()
    sigfillset(&defaults)
    sigdelset(&defaults, SIGKILL)
    sigdelset(&defaults, SIGSTOP)
    try require(posix_spawnattr_setsigdefault(&attributes, &defaults), "signal defaults")

    var argv: [UnsafeMutablePointer<CChar>?] = []
    argv.reserveCapacity(invocation.arguments.count + 2)
    argv.append(strdup(invocation.executable))
    for argument in invocation.arguments { argv.append(strdup(argument)) }
    argv.append(nil)
    defer { argv.forEach { free($0) } }

    var pid: pid_t = 0
    let status = posix_spawn(&pid, invocation.executable, &actions, &attributes, argv, _NSGetEnviron().pointee)
    guard status == 0 else { throw invocation.failure(String(cString: strerror(status))) }
    return pid
}
