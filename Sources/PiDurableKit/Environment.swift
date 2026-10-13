import Foundation

// MARK: Values

/// What a path names (pi-durable `FileKind`).
public enum FileKind: String, Codable, Sendable {
    case file, directory, symlink
}

/// Metadata of one file or directory in an execution environment (pi-durable `FileInfo`).
public struct FileInfo: Codable, Sendable, Hashable {
    public var name: String
    /// The absolute path in the environment.
    public var path: String
    public var kind: FileKind
    public var size: Int
    public var modified: Date

    public init(name: String, path: String, kind: FileKind, size: Int, modified: Date) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
    }

    private enum CodingKeys: String, CodingKey { case name, path, kind, size, mtimeMs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        kind = try container.decodeIfPresent(FileKind.self, forKey: .kind) ?? .file
        size = Int(try container.decodeIfPresent(Double.self, forKey: .size) ?? 0)
        modified = try container.decodeMilliseconds(forKey: .mtimeMs)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(kind, forKey: .kind)
        try container.encode(Double(size), forKey: .size)
        try container.encode((modified.timeIntervalSince1970 * 1000).rounded(), forKey: .mtimeMs)
    }
}

/// Which stream a command's output chunk came from.
public enum StandardStream: String, Codable, Sendable {
    case stdout, stderr
}

/// A command for an environment's shell (pi-durable `Shell.exec`).
public struct ShellCommand: Codable, Sendable, Hashable {
    public enum Program: Sendable, Hashable {
        /// A script run through the environment's shell.
        case script(String)
        /// A program and its arguments, run directly without a shell.
        case argv([String])
    }

    public var program: Program
    /// The working directory, an absolute path in the environment.
    public var cwd: String
    /// Extra environment variables.
    public var environment: [String: String]?
    /// Whether the command inherits the host's environment variables; default `true`.
    public var inheritEnvironment: Bool?
    /// Seconds before the command is killed.
    public var timeout: Double?

    public init(_ program: Program, cwd: String, environment: [String: String]? = nil, inheritEnvironment: Bool? = nil, timeout: Double? = nil) {
        self.program = program
        self.cwd = cwd
        self.environment = environment
        self.inheritEnvironment = inheritEnvironment
        self.timeout = timeout
    }

    private enum CodingKeys: String, CodingKey { case command, cwd, env, inheritEnv, timeout }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let argv = try? container.decode([String].self, forKey: .command) {
            program = .argv(argv)
        } else {
            program = .script(try container.decode(String.self, forKey: .command))
        }
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? "/"
        environment = try container.decodeIfPresent([String: String].self, forKey: .env)
        inheritEnvironment = try container.decodeIfPresent(Bool.self, forKey: .inheritEnv)
        timeout = try container.decodeIfPresent(Double.self, forKey: .timeout)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch program {
        case .script(let script): try container.encode(script, forKey: .command)
        case .argv(let argv): try container.encode(argv, forKey: .command)
        }
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(environment, forKey: .env)
        try container.encodeIfPresent(inheritEnvironment, forKey: .inheritEnv)
        try container.encodeIfPresent(timeout, forKey: .timeout)
    }
}

/// The tail of a command's output a caller keeps and how often it samples it (pi-durable `ShellOutputWindow`). An
/// environment may omit output outside it and report the omission as ``OutputSkip``.
public struct OutputWindow: Codable, Sendable, Hashable {
    /// UTF-8 bytes of decoded text kept at the end of the output.
    public var maxBytes: Int
    /// Lines kept at the end of the output.
    public var maxLines: Int
    /// Minimum pause between the caller's samples of the output, in milliseconds.
    public var minIntervalMs: Double
    /// Each sample also pauses the caller in proportion to its size at this rate.
    public var bytesPerSecond: Double

    public init(maxBytes: Int, maxLines: Int, minIntervalMs: Double, bytesPerSecond: Double) {
        self.maxBytes = maxBytes
        self.maxLines = maxLines
        self.minIntervalMs = minIntervalMs
        self.bytesPerSecond = bytesPerSecond
    }
}

/// Output an environment omitted before a chunk (pi-durable `ShellOutputSkip`).
public struct OutputSkip: Codable, Sendable, Hashable {
    /// UTF-8 byte length of the omitted text.
    public var bytes: Int
    /// Newlines in the omitted text.
    public var newlines: Int
    /// Whether the omitted text ends with a newline.
    public var endsWithNewline: Bool

    public init(bytes: Int, newlines: Int, endsWithNewline: Bool) {
        self.bytes = bytes
        self.newlines = newlines
        self.endsWithNewline = endsWithNewline
    }
}

/// One chunk of a running command's output.
public struct ShellOutput: Sendable, Hashable {
    public let text: String
    public let stream: StandardStream
    /// Output omitted right before this chunk, only with a window.
    public let skipped: OutputSkip?
}

/// What ``ExecutionEnv/listFiles(_:options:)`` lists (pi-durable `ListFilesOptions`).
public struct ListFilesOptions: Encodable, Sendable, Hashable {
    /// Include names starting with `.`; default `true`.
    public var hidden: Bool?
    /// Inside a git work tree, skip what git ignores; default `true`.
    public var gitignore: Bool?
    /// Names of entries to skip with everything below them, such as `node_modules`.
    public var exclude: [String]?
    /// Most entries to list; default 50,000.
    public var maxEntries: Int?
    /// Most bytes of the listing, each entry's UTF-8 path plus two; default 4 MiB.
    public var maxBytes: Int?
    /// Time after which the listing stops, in milliseconds; default 10,000.
    public var timeoutMs: Int?

    public init(
        hidden: Bool? = nil, gitignore: Bool? = nil, exclude: [String]? = nil, maxEntries: Int? = nil, maxBytes: Int? = nil,
        timeoutMs: Int? = nil
    ) {
        self.hidden = hidden
        self.gitignore = gitignore
        self.exclude = exclude
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
        self.timeoutMs = timeoutMs
    }
}

/// A tree listing (pi-durable `FileListing`).
public struct FileListing: Decodable, Sendable, Hashable {
    public struct Entry: Decodable, Sendable, Hashable {
        /// Relative to the listed directory, with `/` separators.
        public let path: String
        /// A symbolic link is listed as such and not followed.
        public let kind: FileKind
    }

    public let entries: [Entry]
    /// A bound ended the listing early.
    public let truncated: Bool
}

/// The outcome of a command (pi-durable `ShellExecResult`).
public struct ShellResult: Decodable, Sendable, Hashable {
    public let exitCode: Int
    /// A temporary file holding the complete output, when it crossed the spill thresholds.
    public let spillPath: String?
}

/// Where lines of a file are (pi-durable `LineScan`).
public struct LineScan: Decodable, Sendable, Hashable {
    /// Newline bytes in the whole file; it has `newlines + 1` lines.
    public let newlines: Int
    /// Byte range of the selected lines, without the newline that ends the last.
    public let start: Int
    public let end: Int
    /// Where the first selected line ends.
    public let firstLineEnd: Int
    /// Where the last selected line starts.
    public let lastLineStart: Int
    /// UTF-8 byte length of the decoded selection and of its first line.
    public let selectedBytes: Int
    public let firstLineBytes: Int
}

/// One file or directory to watch (pi-durable `WatchTarget`).
public struct WatchTarget: Encodable, Sendable, Hashable {
    public var path: String
    /// Watch everything below a directory, not only its entries.
    public var recursive: Bool
    /// Skip entries whose names start with `.`.
    public var excludeHidden: Bool
    /// Skip entries with these names.
    public var excludeNames: [String]

    public init(_ path: String, recursive: Bool = false, excludeHidden: Bool = false, excludeNames: [String] = []) {
        self.path = path
        self.recursive = recursive
        self.excludeHidden = excludeHidden
        self.excludeNames = excludeNames
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encode(path, forKey: AnyKey("path"))
        try container.encode(recursive, forKey: AnyKey("recursive"))
        try container.encode(["hidden": JSONValue.bool(excludeHidden), "names": try JSONValue(encoding: excludeNames)], forKey: AnyKey("exclude"))
    }
}

/// What a file watch reports (pi-durable `WatchChange`).
public enum FileChange: Sendable, Hashable {
    /// Something at or below each path may have changed.
    case paths([String])
    /// Coverage was uncertain for a while; rescan everything watched.
    case overflow
}

// MARK: Live environments

/// An execution environment in use (pi-durable `ExecutionEnv`): the file system and shell that tools such as `read`,
/// `write`, `edit`, and `bash` work in. Paths are absolute in the environment, or relative to ``cwd``.
///
/// Get the environment of a running call with ``ToolCallContext/environment()``, ``TaskRun/environment()``, or
/// ``PromptSection/Input/environment()`` (valid until the call returns), or a conversation's with
/// ``Harness/environment(for:)``. Failures throw ``PiDurableError/file(code:message:path:)`` or
/// ``PiDurableError/execution(code:message:spillPath:)``.
public final class ExecutionEnv: Sendable {
    /// The file namespace: equal ids see the same files at the same paths.
    public let id: String
    let engine: Engine
    let handle: Int
    private let owned: Bool
    private let cwdBox: LockedValue<String>

    struct Description: Decodable, Sendable {
        let handle: Int
        let id: String
        let cwd: String
    }

    init(engine: Engine, description: Description, owned: Bool) {
        self.engine = engine
        self.handle = description.handle
        self.id = description.id
        self.owned = owned
        self.cwdBox = LockedValue(description.cwd)
    }

    deinit {
        if owned { engine.send("env.release", ["env": handle]) }
    }

    /// The directory relative paths resolve against.
    public var cwd: String { cwdBox.value }

    /// Changes the directory relative paths resolve against.
    public func setCwd(_ cwd: String) async throws {
        try await perform("env.setCwd", ["cwd": cwd])
        cwdBox.value = cwd
    }

    func call<Result: Decodable & Sendable>(_ method: String, _ arguments: BridgeArguments = [:]) async throws -> Result {
        var arguments = arguments
        arguments["env"] = handle
        return try await engine.call(method, arguments)
    }

    func perform(_ method: String, _ arguments: BridgeArguments = [:]) async throws {
        var arguments = arguments
        arguments["env"] = handle
        try await engine.perform(method, arguments)
    }

    // MARK: Paths

    public func absolutePath(_ path: String) async throws -> String { try await call("env.absolutePath", ["path": path]) }
    public func joinPath(_ parts: [String]) async throws -> String { try await call("env.joinPath", ["parts": parts]) }
    /// The path with symbolic links resolved.
    public func canonicalPath(_ path: String) async throws -> String { try await call("env.canonicalPath", ["path": path]) }
    public func exists(_ path: String) async throws -> Bool { try await call("env.exists", ["path": path]) }
    /// Metadata of `path`, without following a final symbolic link.
    public func fileInfo(_ path: String) async throws -> FileInfo { try await call("env.fileInfo", ["path": path]) }
    public func listDirectory(_ path: String) async throws -> [FileInfo] { try await call("env.listDir", ["path": path]) }

    /// The files, directories, and symbolic links below a directory, at any depth, for indexes such as file
    /// completion (pi-durable `listFiles`): depth first, parents before their entries, siblings in name order. `.git` is
    /// never listed, and inside a git work tree what its ignore files ignore is skipped.
    public func listFiles(_ path: String = ".", options: ListFilesOptions = ListFilesOptions()) async throws -> FileListing {
        try await call("env.listFiles", ["path": path, "options": options])
    }

    // MARK: Reading

    public func readText(_ path: String) async throws -> String { try await call("env.readText", ["path": path]) }

    /// The file's lines, without line endings.
    public func readLines(_ path: String, maxLines: Int? = nil) async throws -> [String] {
        try await call("env.readTextLines", ["path": path, "maxLines": maxLines])
    }

    public func readData(_ path: String) async throws -> Data {
        let base64: String = try await call("env.readBinary", ["path": path])
        return Data(base64Encoded: base64) ?? Data()
    }

    /// Opens a regular file for positional reads; with `noFollow`, a final symbolic link fails instead of being followed.
    public func openBinaryReader(_ path: String, noFollow: Bool = false) async throws -> BinaryFileReader {
        BinaryFileReader(environment: self, id: try await call("env.openBinaryReader", ["path": path, "noFollow": noFollow]))
    }

    /// Opens a directory for paged listing.
    public func openDirectoryReader(_ path: String) async throws -> DirectoryReader {
        DirectoryReader(environment: self, id: try await call("env.openDirReader", ["path": path]))
    }

    /// Opens a text file for reading line by line.
    public func openLineReader(_ path: String) async throws -> TextLineReader {
        TextLineReader(environment: self, id: try await call("env.openTextLineReader", ["path": path]))
    }

    // MARK: Writing

    public func write(_ text: String, to path: String) async throws { try await perform("env.write", ["path": path, "text": text]) }
    public func write(_ data: Data, to path: String) async throws {
        try await perform("env.write", ["path": path, "base64": data.base64EncodedString()])
    }
    public func append(_ text: String, to path: String) async throws { try await perform("env.append", ["path": path, "text": text]) }
    public func append(_ data: Data, to path: String) async throws {
        try await perform("env.append", ["path": path, "base64": data.base64EncodedString()])
    }
    /// Truncates or extends a file to exactly `size` bytes.
    public func truncate(_ path: String, size: Int) async throws { try await perform("env.truncate", ["path": path, "size": size]) }
    public func flush(_ path: String) async throws { try await perform("env.flush", ["path": path]) }
    public func move(_ path: String, to destination: String) async throws {
        try await perform("env.rename", ["path": path, "destination": destination])
    }
    public func createDirectory(_ path: String, recursive: Bool = false) async throws {
        try await perform("env.createDir", ["path": path, "recursive": recursive])
    }
    public func remove(_ path: String, recursive: Bool = false, force: Bool = false) async throws {
        try await perform("env.remove", ["path": path, "recursive": recursive, "force": force])
    }
    public func createTemporaryDirectory(prefix: String? = nil) async throws -> String {
        try await call("env.createTempDir", ["prefix": prefix])
    }
    public func createTemporaryFile(prefix: String? = nil, suffix: String? = nil) async throws -> String {
        try await call("env.createTempFile", ["prefix": prefix, "suffix": suffix])
    }

    // MARK: Commands

    /// Spill thresholds: once the output crosses either, the complete output goes to a temporary file.
    public struct Spill: Encodable, Sendable, Hashable {
        public var afterBytes: Int
        public var afterLines: Int
        public init(afterBytes: Int, afterLines: Int) {
            self.afterBytes = afterBytes
            self.afterLines = afterLines
        }
    }

    /// Runs a command. Cancelling the calling task kills it.
    ///
    /// - Parameters:
    ///   - program: A script for the environment's shell, or a program and its arguments run without a shell.
    ///   - cwd: The working directory; defaults to ``cwd``.
    ///   - environment: Extra environment variables.
    ///   - inheritEnvironment: Whether the host's environment variables are inherited.
    ///   - timeout: Seconds before the command is killed.
    ///   - spill: Where the output spills to a file.
    ///   - window: The tail of the output you keep, such as ``ToolCallContext/outputWindow``; the environment may omit
    ///     output outside it and report the omission in ``ShellOutput/skipped``.
    ///   - onOutput: Every output chunk as it arrives, with the stream it came from.
    @discardableResult
    public func run(
        _ program: ShellCommand.Program, cwd: String? = nil, environment: [String: String]? = nil,
        inheritEnvironment: Bool? = nil, timeout: Double? = nil, spill: Spill? = nil, window: OutputWindow? = nil,
        onOutput: @escaping @Sendable (ShellOutput) -> Void = { _ in }
    ) async throws -> ShellResult {
        struct Item: Decodable, Sendable {
            let text: String?
            let stream: StandardStream?
            let skipped: OutputSkip?
            let exitCode: Int?
            let spillPath: String?
        }
        let command: JSONValue =
            switch program {
            case .script(let script): .string(script)
            case .argv(let argv): try JSONValue(encoding: argv)
            }
        let items = engine.stream(
            "env.exec",
            [
                "env": handle, "command": command, "cwd": cwd, "environment": environment, "inheritEnv": inheritEnvironment,
                "timeout": timeout, "spill": spill, "window": window,
            ], of: Item.self)
        for try await item in items {
            if let exitCode = item.exitCode { return ShellResult(exitCode: exitCode, spillPath: item.spillPath) }
            if let text = item.text { onOutput(ShellOutput(text: text, stream: item.stream ?? .stdout, skipped: item.skipped)) }
        }
        try Task.checkCancellation()
        throw PiDurableError.execution(code: "aborted", message: "Command aborted", spillPath: nil)
    }

    /// Kills every command this environment still runs; for shutting it down.
    public func cleanup() async throws { try await perform("env.cleanup") }

    // MARK: Watching

    /// Changes to files and directories, until the iteration stops. Coverage is established when the first change
    /// can be reported, so watching before loading misses nothing.
    public func watch(_ targets: [WatchTarget]) -> AsyncThrowingStream<FileChange, Error> {
        let items = engine.stream("env.watch", ["env": handle, "targets": targets], of: JSONValue.self)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await item in items {
                        if let paths = item["paths"]?.arrayValue {
                            continuation.yield(.paths(paths.compactMap(\.stringValue)))
                        } else if item["overflow"]?.boolValue == true {
                            continuation.yield(.overflow)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Positional reads from one opened file (pi-durable `BinaryReader`). Close it when done.
public struct BinaryFileReader: Sendable {
    let environment: ExecutionEnv
    let id: Int

    /// Metadata of the opened file.
    public func info() async throws -> FileInfo { try await environment.engine.call("binaryReader.info", ["reader": id]) }

    /// Up to `length` bytes at `offset`; fewer only at the end of the file.
    public func read(offset: Int, length: Int) async throws -> Data {
        let base64: String = try await environment.engine.call("binaryReader.read", ["reader": id, "offset": offset, "length": length])
        return Data(base64Encoded: base64) ?? Data()
    }

    /// Locates lines `startLine..<endLine` (0-based; `endLine` `nil` for the end of the file) in one pass.
    public func scanLines(from startLine: Int, to endLine: Int? = nil) async throws -> LineScan {
        try await environment.engine.call("binaryReader.scanLines", ["reader": id, "startLine": startLine, "endLine": endLine])
    }

    public func close() async throws { try await environment.engine.perform("binaryReader.close", ["reader": id]) }
}

/// Pages of one directory's entries (pi-durable `DirReader`). Close it when done.
public struct DirectoryReader: Sendable {
    let environment: ExecutionEnv
    let id: Int

    /// Up to `maxEntries` more entries, and whether the listing is done.
    public func next(_ maxEntries: Int = 100) async throws -> (entries: [FileInfo], done: Bool) {
        struct Page: Decodable { let entries: [FileInfo]; let done: Bool }
        let page: Page = try await environment.engine.call("dirReader.next", ["reader": id, "maxEntries": maxEntries])
        return (page.entries, page.done)
    }

    public func close() async throws { try await environment.engine.perform("dirReader.close", ["reader": id]) }
}

/// A text file read line by line (pi-durable `TextLineReader`). Close it when done.
public struct TextLineReader: Sendable {
    let environment: ExecutionEnv
    let id: Int

    /// The next line, and whether a newline ended it; `nil` at the end of the file.
    public func next() async throws -> (text: String, terminated: Bool)? {
        struct Line: Decodable { let text: String; let terminated: Bool }
        let line: Line? = try await environment.engine.call("lineReader.next", ["reader": id])
        return line.map { ($0.text, $0.terminated) }
    }

    public func close() async throws { try await environment.engine.perform("lineReader.close", ["reader": id]) }
}

extension ScopeHandle {
    /// The environment of the running call, task phase, or section.
    func environment() async throws -> ExecutionEnv? {
        let description: ExecutionEnv.Description? = try await call("scope.env")
        return description.map { ExecutionEnv(engine: engine, description: $0, owned: false) }
    }
}

/// A value behind a lock.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: Environments implemented in Swift

/// An execution environment you implement in Swift, such as a remote machine or an in-memory file system, for
/// ``ExecutionEnvironment/custom(_:)``.
///
/// Paths are absolute and normalized (`/notes/todo.md`). Throw ``PiDurableError/file(code:message:path:)`` with
/// pi-durable's codes (`not_found` in particular, which tools rely on) and
/// ``PiDurableError/execution(code:message:spillPath:)`` from ``run(_:output:)``. Every other error is `unknown`.
public protocol CustomExecutionEnvironment: Sendable {
    /// The file namespace: environments with equal ids see the same files at the same paths. `edit` and `write`
    /// serialize changes to one file by this id and the path.
    var id: String { get }
    /// Whether ``run(_:output:)`` is implemented. Default `false`.
    var supportsShell: Bool { get }

    /// Metadata of `path`; with `followSymlinks` false, a final symbolic link is described itself.
    func fileInfo(at path: String, followSymlinks: Bool) async throws -> FileInfo
    func readFile(at path: String) async throws -> Data
    /// Up to `length` bytes at `offset`. Default: reads the whole file.
    func readFile(at path: String, offset: Int, length: Int) async throws -> Data
    func writeFile(at path: String, data: Data, append: Bool) async throws
    /// Default: reads, resizes, and writes the whole file.
    func truncateFile(at path: String, size: Int) async throws
    /// Default: does nothing.
    func flushFile(at path: String) async throws
    func moveItem(at path: String, to destination: String) async throws
    func contentsOfDirectory(at path: String) async throws -> [FileInfo]
    func createDirectory(at path: String, recursive: Bool) async throws
    func removeItem(at path: String, recursive: Bool, force: Bool) async throws
    /// The path with symbolic links resolved. Default: the path itself.
    func canonicalPath(_ path: String) async throws -> String
    /// Runs a command, reporting output as it arrives, and returns its exit code. Default: throws `shell_unavailable`.
    func run(_ command: ShellCommand, output: @escaping @Sendable (String, StandardStream) -> Void) async throws -> Int
    /// Releases resources; kills commands still running. Default: does nothing.
    func cleanup() async throws
}

extension CustomExecutionEnvironment {
    public var supportsShell: Bool { false }

    public func readFile(at path: String, offset: Int, length: Int) async throws -> Data {
        let data = try await readFile(at: path)
        guard offset < data.count else { return Data() }
        return data.subdata(in: offset..<min(data.count, offset + length))
    }

    public func truncateFile(at path: String, size: Int) async throws {
        var data = try await readFile(at: path)
        if data.count > size { data = data.prefix(size) } else { data.append(Data(count: size - data.count)) }
        try await writeFile(at: path, data: data, append: false)
    }

    public func flushFile(at path: String) async throws {}
    public func canonicalPath(_ path: String) async throws -> String { path }

    public func run(_ command: ShellCommand, output: @escaping @Sendable (String, StandardStream) -> Void) async throws -> Int {
        throw PiDurableError.execution(code: "shell_unavailable", message: "There is no shell in this environment", spillPath: nil)
    }

    public func cleanup() async throws {}
}
