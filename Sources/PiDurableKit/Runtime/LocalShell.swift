#if os(macOS)
import Foundation

/// Runs commands for the macOS environments with a shell (``ExecutionEnvironment/local`` and
/// ``ExecutionEnvironment/directory(_:shell:)``), like pi-durable's `NodeExecutionEnv`: a script runs in `/bin/bash -c`,
/// an argv array runs its program directly. Each command gets its own process group, so a timeout or cancellation
/// kills everything it started.
enum LocalShell {
    static func run(_ command: ShellCommand, output: @escaping @Sendable (String, StandardStream) -> Void) async throws -> Int {
        let arguments: [String]
        switch command.program {
        case .script(let script): arguments = ["/bin/bash", "-c", script]
        case .argv(let argv):
            guard let program = argv.first else {
                throw PiDurableError.execution(code: "spawn_error", message: "Empty argv: no program to run", spillPath: nil)
            }
            arguments = [resolve(program, environment: environment(command))] + argv.dropFirst()
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: command.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PiDurableError.execution(
                code: "spawn_error", message: "Working directory does not exist: \(command.cwd)", spillPath: nil)
        }
        let process = try SpawnedProcess(arguments: arguments, environment: environment(command), cwd: command.cwd, output: output)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int?.self) { group in
                group.addTask { await process.wait() }
                if let timeout = command.timeout {
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeout))
                        return nil
                    }
                }
                let first = try await group.next()!
                group.cancelAll()
                guard let exitCode = first else {
                    process.kill()
                    _ = await process.wait()
                    throw PiDurableError.execution(code: "timeout", message: "Command timed out after \(command.timeout ?? 0) seconds", spillPath: nil)
                }
                if Task.isCancelled {
                    throw PiDurableError.execution(code: "aborted", message: "Command aborted", spillPath: nil)
                }
                return exitCode
            }
        } onCancel: {
            process.kill()
        }
    }

    private static func environment(_ command: ShellCommand) -> [String: String] {
        var environment = command.inheritEnvironment == false ? [:] : ProcessInfo.processInfo.environment
        for (key, value) in command.environment ?? [:] { environment[key] = value }
        return environment
    }

    /// The program's path, looked up in `PATH` unless it names a path.
    private static func resolve(_ program: String, environment: [String: String]) -> String {
        guard !program.contains("/") else { return program }
        for directory in (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":") {
            let candidate = "\(directory)/\(program)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return program
    }
}

/// One spawned process in its own process group, with its output streamed as it arrives.
private final class SpawnedProcess: @unchecked Sendable {
    private let pid: pid_t
    private let lock = NSLock()
    private var exitCode: Int?
    private var waiters: [CheckedContinuation<Int, Never>] = []
    private var openStreams = 2
    private var exitStatus: Int?

    init(arguments: [String], environment: [String: String], cwd: String, output: @escaping @Sendable (String, StandardStream) -> Void) throws {
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw PiDurableError.execution(code: "spawn_error", message: String(cString: strerror(errno)), spillPath: nil)
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)
        for descriptor in [stdoutPipe[0], stdoutPipe[1], stderrPipe[0], stderrPipe[1]] {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        posix_spawn_file_actions_addchdir_np(&actions, cwd)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, envp)
        close(stdoutPipe[1])
        close(stderrPipe[1])
        guard status == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw PiDurableError.execution(
                code: "spawn_error", message: "\(arguments[0]): \(String(cString: strerror(status)))", spillPath: nil)
        }
        self.pid = pid
        read(stdoutPipe[0], as: .stdout, output: output)
        read(stderrPipe[0], as: .stderr, output: output)
        DispatchQueue.global().async { [self] in
            var status: Int32 = 0
            while waitpid(self.pid, &status, 0) == -1 && errno == EINTR {}
            let code: Int
            if status & 0x7f == 0 {
                code = Int((status >> 8) & 0xff)
            } else {
                code = 128 + Int(status & 0x7f)
            }
            finish(exitStatus: code)
        }
    }

    /// Reads one pipe on its own thread, decoding UTF-8 across chunk boundaries.
    private func read(_ descriptor: Int32, as stream: StandardStream, output: @escaping @Sendable (String, StandardStream) -> Void) {
        Thread.detachNewThread { [self] in
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                pending.append(buffer, count: count)
                let complete = Self.completeUTF8Prefix(pending)
                if complete > 0 {
                    output(String(decoding: pending.prefix(complete), as: UTF8.self), stream)
                    pending.removeFirst(complete)
                }
            }
            if !pending.isEmpty { output(String(decoding: pending, as: UTF8.self), stream) }
            close(descriptor)
            finish(exitStatus: nil)
        }
    }

    /// The length of `data` without an incomplete UTF-8 sequence at its end.
    private static func completeUTF8Prefix(_ data: Data) -> Int {
        let bytes = [UInt8](data.suffix(3))
        for back in 1...bytes.count {
            let byte = bytes[bytes.count - back]
            if byte & 0b1100_0000 == 0b1000_0000 { continue }
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return length > back ? data.count - back : data.count
        }
        return data.count
    }

    /// The process ends once it exited and both pipes closed, so all output is delivered before the exit code.
    private func finish(exitStatus: Int?) {
        let resumed: (Int, [CheckedContinuation<Int, Never>])? = lock.withLock {
            if let exitStatus { self.exitStatus = exitStatus } else { openStreams -= 1 }
            guard let status = self.exitStatus, openStreams == 0, exitCode == nil else { return nil }
            exitCode = status
            defer { waiters = [] }
            return (status, waiters)
        }
        if let (code, waiters) = resumed { waiters.forEach { $0.resume(returning: code) } }
    }

    func wait() async -> Int? {
        await withCheckedContinuation { continuation in
            let code: Int? = lock.withLock {
                if let exitCode { return exitCode }
                waiters.append(continuation)
                return nil
            }
            if let code { continuation.resume(returning: code) }
        }
    }

    /// Kills the process group, then the process.
    func kill() {
        Darwin.kill(-pid, SIGKILL)
        Darwin.kill(pid, SIGKILL)
    }
}
#endif
