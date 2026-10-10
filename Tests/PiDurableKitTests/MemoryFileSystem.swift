import Foundation
@testable import PiDurableKit

/// An in-memory ``CustomExecutionEnvironment``, without a shell.
actor MemoryFileSystem: CustomExecutionEnvironment {
    enum Node {
        case file(Data, Date)
        case directory(Date)
    }

    nonisolated let id: String
    private var nodes: [String: Node] = ["/": .directory(Date())]

    init(id: String = "memory:\(UUID().uuidString)") {
        self.id = id
    }

    private func notFound(_ path: String) -> PiDurableError {
        .file(code: "not_found", message: "\(path): No such file or directory", path: path)
    }

    private func parent(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func info(_ path: String, _ node: Node) -> FileInfo {
        let name = path == "/" ? "/" : (path as NSString).lastPathComponent
        switch node {
        case .file(let data, let modified): return FileInfo(name: name, path: path, kind: .file, size: data.count, modified: modified)
        case .directory(let modified): return FileInfo(name: name, path: path, kind: .directory, size: 0, modified: modified)
        }
    }

    func fileInfo(at path: String, followSymlinks: Bool) async throws -> FileInfo {
        guard let node = nodes[path] else { throw notFound(path) }
        return info(path, node)
    }

    func readFile(at path: String) async throws -> Data {
        switch nodes[path] {
        case .file(let data, _)?: return data
        case .directory?: throw PiDurableError.file(code: "is_directory", message: "\(path) is a directory", path: path)
        case nil: throw notFound(path)
        }
    }

    func writeFile(at path: String, data: Data, append: Bool) async throws {
        guard case .directory? = nodes[parent(path)] else { throw notFound(parent(path)) }
        if case .directory? = nodes[path] { throw PiDurableError.file(code: "is_directory", message: path, path: path) }
        var contents = Data()
        if append, case .file(let existing, _)? = nodes[path] { contents = existing }
        contents.append(data)
        nodes[path] = .file(contents, Date())
    }

    func moveItem(at path: String, to destination: String) async throws {
        guard nodes[path] != nil else { throw notFound(path) }
        for (key, node) in nodes where key == path || key.hasPrefix(path + "/") {
            nodes[destination + key.dropFirst(path.count)] = node
            nodes[key] = nil
        }
    }

    func contentsOfDirectory(at path: String) async throws -> [FileInfo] {
        switch nodes[path] {
        case .directory?: break
        case .file?: throw PiDurableError.file(code: "not_directory", message: "\(path) is not a directory", path: path)
        case nil: throw notFound(path)
        }
        return nodes.filter { $0.key != path && parent($0.key) == path }
            .map { info($0.key, $0.value) }
            .sorted { $0.name < $1.name }
    }

    func createDirectory(at path: String, recursive: Bool) async throws {
        if nodes[path] != nil {
            if recursive, case .directory? = nodes[path] { return }
            throw PiDurableError.file(code: "invalid", message: "\(path) exists", path: path)
        }
        if nodes[parent(path)] == nil {
            guard recursive else { throw notFound(parent(path)) }
            try await createDirectory(at: parent(path), recursive: true)
        }
        nodes[path] = .directory(Date())
    }

    func removeItem(at path: String, recursive: Bool, force: Bool) async throws {
        guard nodes[path] != nil else {
            if force { return }
            throw notFound(path)
        }
        let children = nodes.keys.filter { $0.hasPrefix(path + "/") }
        if !children.isEmpty && !recursive {
            throw PiDurableError.file(code: "invalid", message: "\(path) is not empty", path: path)
        }
        for child in children { nodes[child] = nil }
        nodes[path] = nil
    }

    func files() -> [String: String] {
        var result: [String: String] = [:]
        for case (let path, .file(let data, _)) in nodes { result[path] = String(decoding: data, as: UTF8.self) }
        return result
    }
}
