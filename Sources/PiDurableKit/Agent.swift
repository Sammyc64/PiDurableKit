import Foundation

/// A model, by provider and ID, resolved through ``Models``.
public struct ModelRef: Codable, Hashable, Sendable, CustomStringConvertible {
    public var provider: ProviderID
    public var modelId: String

    public init(provider: ProviderID, modelId: String) {
        self.provider = provider
        self.modelId = modelId
    }

    public var description: String { "\(provider)/\(modelId)" }

    public static func anthropic(_ modelId: String) -> ModelRef { ModelRef(provider: .anthropic, modelId: modelId) }
    public static func openAI(_ modelId: String) -> ModelRef { ModelRef(provider: .openAI, modelId: modelId) }
    public static func google(_ modelId: String) -> ModelRef { ModelRef(provider: .google, modelId: modelId) }
    public static func openRouter(_ modelId: String) -> ModelRef { ModelRef(provider: .openRouter, modelId: modelId) }
}

/// How much a reasoning model thinks before answering.
public enum ThinkingLevel: String, Codable, Sendable, CaseIterable {
    case off, minimal, low, medium, high, xhigh, max
}

/// A conversation's stored agent choices (`pi.agent`). Unset fields follow the harness defaults.
public struct AgentState: Codable, Sendable, Hashable {
    public var model: ModelRef?
    public var thinkingLevel: ThinkingLevel?
    /// The extension selection: exactly some extensions, or an edit of the harness default.
    public var extensions: AgentChange.Extensions?
    /// The tool filter, which tools are enabled: exactly some tools, or all but some.
    public var tools: AgentChange.Tools?
    /// Which enabled tools the model is offered, including loaded deferred ones.
    public var modelTools: AgentChange.ModelTools?
    public var instructions: String?
    public var cwd: String?

    public init() {}
}

/// A conversation's agent, resolved against the installed extensions and the settings.
public struct Agent: Codable, Sendable, Hashable {
    /// A system prompt section, by key.
    public struct Section: Codable, Sendable, Hashable {
        public var key: String
        /// Whether the text is wrapped as `<key>\\n…\\n</key>`.
        public var tag: Bool
    }

    public var model: ModelRef?
    public var thinkingLevel: ThinkingLevel
    /// Selected extensions, in order.
    public var extensions: [String]
    /// The tools a request offers the model, in order: enabled, callable by the model, and selected by `modelTools`.
    public var tools: [String]
    /// The tools nested calls resolve among, in order: enabled and callable by tools.
    public var callable: [String]
    /// Enabled deferred tools the model may call but is not offered yet, in registry order: what a tool search loads.
    public var deferred: [String]
    /// The system prompt sections, in render order: the extensions' sections, then ``instructions`` when set as the
    /// section ``PromptSection/instructionsKey``.
    public var sections: [Section]
    public var instructions: String?
    public var cwd: String?

    private enum CodingKeys: String, CodingKey {
        case model, thinkingLevel, extensions, tools, callable, deferred, sections, instructions, cwd
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(ModelRef.self, forKey: .model)
        thinkingLevel = try container.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel) ?? .off
        extensions = try container.decodeIfPresent([String].self, forKey: .extensions) ?? []
        tools = try container.decodeIfPresent([String].self, forKey: .tools) ?? []
        callable = try container.decodeIfPresent([String].self, forKey: .callable) ?? []
        deferred = try container.decodeIfPresent([String].self, forKey: .deferred) ?? []
        sections = try container.decodeIfPresent([Section].self, forKey: .sections) ?? []
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
    }
}

/// A change to a conversation's agent (`configure()`).
///
/// Fields left `nil` keep their stored value; fields listed in `reset` return to the harness default.
///
/// ```swift
/// try await conversation.configure(AgentChange(model: .anthropic("claude-sonnet-4-5"), thinkingLevel: .high))
/// try await conversation.configure(AgentChange(reset: [.tools, .instructions]))
/// ```
public struct AgentChange: Encodable, Sendable, Hashable {
    /// A field of the agent that can be reset to the harness default.
    public enum Field: String, Sendable, Hashable, CaseIterable {
        case model, thinkingLevel, extensions, tools, modelTools, instructions, cwd
    }

    /// Which extensions a conversation selects.
    public enum Extensions: Codable, Sendable, Hashable {
        /// Exactly these extensions, in order.
        case only([String])
        /// The harness default, with some added and some removed.
        case edit(add: [String] = [], remove: [String] = [])

        public static func add(_ extensions: Extension...) -> Extensions { .edit(add: extensions.map(\.name)) }
        public static func remove(_ extensions: Extension...) -> Extensions { .edit(remove: extensions.map(\.name)) }
        public static func only(_ extensions: Extension...) -> Extensions { .only(extensions.map(\.name)) }

        public init(from decoder: Decoder) throws {
            if let names = try? decoder.singleValueContainer().decode([String].self) {
                self = .only(names)
                return
            }
            let container = try decoder.container(keyedBy: AnyKey.self)
            self = .edit(
                add: try container.decodeIfPresent([String].self, forKey: AnyKey("add")) ?? [],
                remove: try container.decodeIfPresent([String].self, forKey: AnyKey("remove")) ?? [])
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .only(let names):
                var container = encoder.singleValueContainer()
                try container.encode(names)
            case .edit(let add, let remove):
                var container = encoder.container(keyedBy: AnyKey.self)
                try container.encode(add, forKey: AnyKey("add"))
                try container.encode(remove, forKey: AnyKey("remove"))
            }
        }
    }

    /// Which tools of the selected extensions a conversation offers.
    public enum Tools: Codable, Sendable, Hashable {
        /// Exactly these tools, in order.
        case only([String])
        /// Every tool except these.
        case remove([String])

        public static func only(_ tools: Tool...) -> Tools { .only(tools.map(\.name)) }
        public static func remove(_ tools: Tool...) -> Tools { .remove(tools.map(\.name)) }

        public init(from decoder: Decoder) throws {
            if let names = try? decoder.singleValueContainer().decode([String].self) {
                self = .only(names)
                return
            }
            let container = try decoder.container(keyedBy: AnyKey.self)
            self = .remove(try container.decodeIfPresent([String].self, forKey: AnyKey("remove")) ?? [])
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .only(let names):
                var container = encoder.singleValueContainer()
                try container.encode(names)
            case .remove(let names):
                var container = encoder.container(keyedBy: AnyKey.self)
                try container.encode(names, forKey: AnyKey("remove"))
            }
        }
    }

    /// Which of the enabled tools callable by the model it is offered (pi-durable `modelTools`). Never widens: other
    /// tools can still call the ones it leaves out.
    public enum ModelTools: Codable, Sendable, Hashable {
        /// Exactly these, in order, deferred ones too.
        case only([String])
        /// Every such tool except deferred ones and those in `remove`, followed by the deferred tools in `add`.
        case edit(remove: [String] = [], add: [String] = [])

        public static func only(_ tools: Tool...) -> ModelTools { .only(tools.map(\.name)) }
        public static func remove(_ tools: Tool...) -> ModelTools { .edit(remove: tools.map(\.name)) }
        public static func add(_ tools: Tool...) -> ModelTools { .edit(add: tools.map(\.name)) }

        public init(from decoder: Decoder) throws {
            if let names = try? decoder.singleValueContainer().decode([String].self) {
                self = .only(names)
                return
            }
            let container = try decoder.container(keyedBy: AnyKey.self)
            self = .edit(
                remove: try container.decodeIfPresent([String].self, forKey: AnyKey("remove")) ?? [],
                add: try container.decodeIfPresent([String].self, forKey: AnyKey("add")) ?? [])
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .only(let names):
                var container = encoder.singleValueContainer()
                try container.encode(names)
            case .edit(let remove, let add):
                var container = encoder.container(keyedBy: AnyKey.self)
                if !remove.isEmpty { try container.encode(remove, forKey: AnyKey("remove")) }
                if !add.isEmpty { try container.encode(add, forKey: AnyKey("add")) }
            }
        }
    }

    public var model: ModelRef?
    public var thinkingLevel: ThinkingLevel?
    public var extensions: Extensions?
    public var tools: Tools?
    /// Which of the enabled tools the model is offered; replaces the stored filter as a whole.
    public var modelTools: ModelTools?
    /// Rendered last in the system prompt, as the section `instructions`.
    public var instructions: String?
    /// The working directory passed to the execution environment.
    public var cwd: String?
    /// Fields cleared back to the harness default.
    public var reset: Set<Field>

    public init(
        model: ModelRef? = nil,
        thinkingLevel: ThinkingLevel? = nil,
        extensions: Extensions? = nil,
        tools: Tools? = nil,
        modelTools: ModelTools? = nil,
        instructions: String? = nil,
        cwd: String? = nil,
        reset: Set<Field> = []
    ) {
        self.modelTools = modelTools
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.extensions = extensions
        self.tools = tools
        self.instructions = instructions
        self.cwd = cwd
        self.reset = reset
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        for field in reset { try container.encodeNil(forKey: AnyKey(field.rawValue)) }
        try container.encodeIfPresent(model, forKey: AnyKey("model"))
        try container.encodeIfPresent(thinkingLevel, forKey: AnyKey("thinkingLevel"))
        try container.encodeIfPresent(instructions, forKey: AnyKey("instructions"))
        try container.encodeIfPresent(cwd, forKey: AnyKey("cwd"))
        try container.encodeIfPresent(extensions, forKey: AnyKey("extensions"))
        try container.encodeIfPresent(tools, forKey: AnyKey("tools"))
        try container.encodeIfPresent(modelTools, forKey: AnyKey("modelTools"))
    }
}
