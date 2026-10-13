import Foundation

/// One published state of a harness's registry (pi-durable `RegistrySnapshot`): the installed extensions, what each
/// brings, and every task definition, built-in ones included.
public struct RegistrySnapshot: Decodable, Sendable, Hashable {
    /// One installed extension.
    public struct InstalledExtension: Decodable, Sendable, Hashable, Identifiable {
        /// One tool of an extension, with its pi-ai `Tool` fields.
        public struct ToolInfo: Decodable, Sendable, Hashable {
            public let name: String
            public let description: String
            /// The JSON schema of the tool's arguments.
            public let parameters: JSONValue
            public let replay: Tool.Replay
            public let executionMode: Settings.ToolExecution?
            /// The JSON schema of the tool's structured output.
            public let structuredOutputSchema: JSONValue?
            /// Who may call the tool.
            public let callers: [Tool.Caller]
            /// Whether the tool is kept from the model until loaded.
            public let deferred: Bool
        }

        /// One wrap: the tool or section it decorates.
        public enum WrapTarget: Decodable, Sendable, Hashable {
            case tool(String)
            case section(String)

            public init(from decoder: Decoder) throws {
                let json = try JSONValue(from: decoder)
                if let tool = json["tool"]?.stringValue { self = .tool(tool) } else { self = .section(json["section"]?.stringValue ?? "") }
            }
        }

        public var id: String { name }
        public let name: String
        public let tools: [ToolInfo]
        public let sections: [Agent.Section]
        /// The task names the extension's hooks attach to, such as `pi.tool`.
        public let hooks: [String]
        public let wraps: [WrapTarget]
        /// The names of the extension's task definitions.
        public let tasks: [String]
    }

    /// A registered task definition.
    public struct TaskDefinition: Decodable, Sendable, Hashable {
        public let name: String
        public let version: Int
    }

    /// The installed extensions, in install order.
    public let extensions: [InstalledExtension]
    /// Every task definition: the built-in `pi.generation`, `pi.tool`, and `pi.compaction`, and the installed ones.
    public let tasks: [TaskDefinition]

    /// An installed extension by name.
    public func `extension`(_ name: String) -> InstalledExtension? { extensions.first { $0.name == name } }

    /// Every installed tool with its extension, in install order. Names may repeat across extensions.
    public var tools: [(extension: String, tool: InstalledExtension.ToolInfo)] {
        extensions.flatMap { installed in installed.tools.map { (installed.name, $0) } }
    }
}

extension Settings.ToolExecution: Hashable {}

extension Harness {
    /// The current registry: the installed extensions and every task definition.
    public func registry() async throws -> RegistrySnapshot {
        try await call("harness.registry")
    }

    /// The settings every conversation runs with: the harness's ``Settings`` with every unset field resolved to
    /// pi-durable's default.
    public func resolvedSettings() async throws -> Settings {
        try await call("harness.settings")
    }
}

extension Runtime {
    /// pi-durable's default settings (`DEFAULT_RETRY_POLICY`, `DEFAULT_COMPACTION_POLICY`, `DEFAULT_PROGRESS_POLICY`,
    /// and the other defaults): what a harness with `Settings()` runs with.
    public func defaultSettings() async throws -> Settings {
        try await engine.call("settings.defaults")
    }
}

extension ToolCallContext {
    /// The registry as this call's task phase took it (pi-durable `api.registry`).
    public func registry() async throws -> RegistrySnapshot {
        try await handle.call("scope.registry")
    }
}

extension TaskRun {
    /// The registry of the current phase (pi-durable `runtime.registry`); refreshed at every phase boundary.
    public func registry() async throws -> RegistrySnapshot {
        try await handle.call("scope.registry")
    }

    /// The harness's settings, resolved over pi-durable's defaults (pi-durable `runtime.settings`).
    public func settings() async throws -> Settings {
        try await handle.call("scope.settings")
    }
}

extension PromptSection {
    /// The reserved section key of an agent's ``AgentChange/instructions`` (pi-durable `INSTRUCTIONS_KEY`).
    public static let instructionsKey = "instructions"
}
