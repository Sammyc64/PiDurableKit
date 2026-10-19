import Foundation

/// A named bundle of tools, system prompt sections, hooks, wraps, and durable tasks (pi-durable `defineExtension`).
///
/// ```swift
/// let assistant = Extension("assistant") {
///     PromptSection("preamble", tag: false, text: "You are a concise assistant on an iPhone.")
///     weather
///     Hook.beforeTool { call, _ in
///         call.name == "delete_note" ? .block("Deleting notes needs approval") : .allow
///     }
/// }
/// ```
///
/// Conversations select extensions by name. By default every conversation selects every installed extension,
/// in install order. A later extension's tool replaces an earlier one with the same name.
public struct Extension: Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public var tools: [Tool]
    public var sections: [PromptSection]
    public var hooks: [Hook]
    /// Decorators of tools and sections of any selected extension, applied where this extension is selected.
    public var wraps: [Wrap]
    /// Durable task types, resolved by name for every task whatever the conversation selects.
    public var tasks: [AnyTaskType]
    let builtin: Builtin?
    let javaScript: (source: String, sourceURL: URL?)?

    public init(
        _ name: String, tools: [Tool] = [], sections: [PromptSection] = [], hooks: [Hook] = [], wraps: [Wrap] = [],
        tasks: [AnyTaskType] = []
    ) {
        self.name = name
        self.tools = tools
        self.sections = sections
        self.hooks = hooks
        self.wraps = wraps
        self.tasks = tasks
        self.builtin = nil
        self.javaScript = nil
    }

    public init(_ name: String, @ExtensionBuilder _ content: () -> [ExtensionComponent]) {
        self.init(name)
        for component in content() {
            switch component {
            case .tool(let tool): tools.append(tool)
            case .section(let section): sections.append(section)
            case .hook(let hook): hooks.append(hook)
            case .wrap(let wrap): wraps.append(wrap)
            case .task(let task): tasks.append(task)
            }
        }
    }

    /// An extension pi-durable provides.
    enum Builtin {
        case tools([BuiltinTool], images: (any ImageProcessor)?)
        case toolSearch
        case codemode(CodemodeOptions)

        var tools: [BuiltinTool] {
            if case .tools(let tools, _) = self { return tools }
            return []
        }
    }

    private init(builtin: Builtin, name: String) {
        self.name = name
        self.tools = []
        self.sections = []
        self.hooks = []
        self.wraps = []
        self.tasks = []
        self.builtin = builtin
        self.javaScript = nil
    }

    /// A pi-durable extension written in JavaScript, evaluated in the harness's runtime and installed unchanged.
    ///
    /// `source` is a CommonJS module whose `module.exports` is a pi-durable extension. It can `require`
    /// `@earendil-works/pi-durable`, `@earendil-works/pi-durable/tools`, `@earendil-works/pi-durable/env`,
    /// `@earendil-works/pi-durable/tool-search`, `@earendil-works/pi-durable/codemode`,
    /// `@earendil-works/pi-codemode/portable`, `@earendil-works/pi-ai`, `@earendil-works/chord/context`, and
    /// `@earendil-works/chord/output`:
    ///
    /// ```js
    /// const { defineExtension, defineTool } = require("@earendil-works/pi-durable");
    /// const { Type } = require("@earendil-works/pi-ai");
    ///
    /// module.exports = defineExtension({
    ///     name: "dice",
    ///     tools: [defineTool({
    ///         name: "roll", description: "Roll a die", parameters: Type.Object({ sides: Type.Number() }),
    ///         execute: async (args) => ({ output: [{ type: "text", text: String(1 + Math.floor(Math.random() * args.sides)) }] }),
    ///     })],
    /// });
    /// ```
    ///
    /// As in pi-durable, extension code is not sandboxed: it runs with the same access as pi-durable itself, so install
    /// only code you trust. Installing fails if the module does not export an extension named `name`.
    public init(_ name: String, javaScript source: String, sourceURL: URL? = nil) {
        self.name = name
        self.tools = []
        self.sections = []
        self.hooks = []
        self.wraps = []
        self.tasks = []
        self.builtin = nil
        self.javaScript = (source, sourceURL)
    }

    /// pi-durable's `read`, `write`, and `edit` tools, working in the harness's ``ExecutionEnvironment``, and with
    /// `shell` its `bash` tool too, like pi-durable's `createCodingTools()`. Commands need an environment with a shell,
    /// such as `ExecutionEnvironment.local` on macOS; there is none on iOS.
    ///
    /// - Parameters:
    ///   - name: The extension's name.
    ///   - shell: Include `bash`.
    ///   - images: Prepares the images `read` returns: orients, converts, and shrinks them to the model's limits. Without
    ///     one, images within the byte limit pass through as they are. ``NativeImageProcessor`` uses ImageIO.
    public static func codingTools(name: String = "coding", shell: Bool = false, images: (any ImageProcessor)? = nil) -> Extension {
        Extension(builtin: .tools(shell ? [.read, .write, .edit, .bash()] : [.read, .write, .edit], images: images), name: name)
    }

    /// An extension of pi-durable's built-in tools (`@earendil-works/pi-durable/tools`), in order.
    ///
    /// ```swift
    /// let readOnly = Extension.builtinTools(name: "read-only", [.read], images: .native)
    /// let shell = Extension.builtinTools(name: "shell", [.bash(commandPrefix: "source .venv/bin/activate")])
    /// ```
    ///
    /// - Parameters:
    ///   - name: The extension's name.
    ///   - tools: The tools, in order.
    ///   - images: Prepares the images `read` returns; see ``codingTools(name:shell:images:)``.
    public static func builtinTools(name: String, _ tools: [BuiltinTool], images: (any ImageProcessor)? = nil) -> Extension {
        Extension(builtin: .tools(tools, images: images), name: name)
    }

    /// pi-durable's `tool_search` tool (`@earendil-works/pi-durable/tool-search`): the model searches the deferred tools
    /// it is not offered yet (``Tool/deferred``), and the matches are loaded, so the next request offers them. Select it
    /// where the model should find deferred tools.
    public static func toolSearch(name: String = "tool-search") -> Extension {
        Extension(builtin: .toolSearch, name: name)
    }

    /// pi-durable's durable code mode (`@earendil-works/pi-durable/codemode`): a `codemode` tool whose JavaScript scripts
    /// call the conversation's tools as nested calls and survive a restart, and a `codemode` prompt section listing the
    /// tools scripts can call.
    ///
    /// Scripts run in QuickJS (WebAssembly), each in a JavaScriptCore context on a thread of its own, so one that
    /// computes doesn't hold up the runtime's other work; tools still run in the runtime. JavaScriptCore runs
    /// WebAssembly on macOS, iOS devices, and the iOS Simulator.
    public static func codemode(name: String = "codemode", _ options: CodemodeOptions = CodemodeOptions()) -> Extension {
        Extension(builtin: .codemode(options), name: name)
    }

    var specification: BridgeArguments {
        switch builtin {
        case .tools(let tools, let images)?:
            return [
                "name": name, "builtin": "tools",
                "builtinTools": tools.enumerated().map { $1.specification(index: $0, images: images != nil) },
            ]
        case .toolSearch?:
            return ["name": name, "builtin": "toolSearch"]
        case .codemode(let options)?:
            return [
                "name": name, "builtin": "codemode", "wasmPath": CodemodeOptions.quickJSPath,
                "namespaces": options.namespaces.isEmpty ? nil : options.namespaces, "inlineBudget": options.inlineBudget,
                "models": options.models, "interruptBudget": options.interruptBudget,
                "memoryLimitBytes": options.memoryLimitBytes,
            ]
        case nil: break
        }
        if let javaScript {
            return ["name": name, "javaScript": javaScript.source, "sourceURL": javaScript.sourceURL?.absoluteString]
        }
        var hookFlags: [String: Bool] = [:]
        var taskHooks: [[String: String]] = []
        for hook in hooks {
            if case .task(let task, let name, _) = hook.kind {
                if !taskHooks.contains(["task": task, "name": name]) { taskHooks.append(["task": task, "name": name]) }
            } else {
                hookFlags[hook.kind.name] = true
            }
        }
        return [
            "name": name,
            "tools": tools.map(\.specification),
            "sections": sections.map(\.specification),
            "hooks": hookFlags,
            "taskHooks": taskHooks,
            "wraps": wraps.enumerated().map { index, wrap in wrap.specification(index: index) },
            "tasks": tasks.map(\.specification),
        ]
    }
}

/// One part of an ``Extension`` built with ``ExtensionBuilder``.
public enum ExtensionComponent: Sendable {
    case tool(Tool)
    case section(PromptSection)
    case hook(Hook)
    case wrap(Wrap)
    case task(AnyTaskType)
}

@resultBuilder
public enum ExtensionBuilder {
    public static func buildExpression(_ tool: Tool) -> [ExtensionComponent] { [.tool(tool)] }
    public static func buildExpression(_ tools: [Tool]) -> [ExtensionComponent] { tools.map { .tool($0) } }
    public static func buildExpression(_ section: PromptSection) -> [ExtensionComponent] { [.section(section)] }
    public static func buildExpression(_ hook: Hook) -> [ExtensionComponent] { [.hook(hook)] }
    public static func buildExpression(_ wrap: Wrap) -> [ExtensionComponent] { [.wrap(wrap)] }
    public static func buildExpression<I, S, R>(_ task: TaskType<I, S, R>) -> [ExtensionComponent] { [.task(task.erased)] }
    public static func buildBlock(_ components: [ExtensionComponent]...) -> [ExtensionComponent] { components.flatMap { $0 } }
    public static func buildOptional(_ component: [ExtensionComponent]?) -> [ExtensionComponent] { component ?? [] }
    public static func buildEither(first component: [ExtensionComponent]) -> [ExtensionComponent] { component }
    public static func buildEither(second component: [ExtensionComponent]) -> [ExtensionComponent] { component }
    public static func buildArray(_ components: [[ExtensionComponent]]) -> [ExtensionComponent] { components.flatMap { $0 } }
}

extension TaskType {
    /// This task type, for ``Extension/tasks``.
    public var any: AnyTaskType { erased }
}

/// A system prompt section (pi-durable `section`). The selected extensions' sections render in order before each
/// model request; only sections that changed are sent again, which keeps provider prompt caches warm.
public struct PromptSection: Sendable {
    /// What a section can see when it renders.
    public struct Input: Sendable {
        public let conversationId: ConversationID
        /// The request's agent; its `tools` are the tools this request offers.
        public let agent: Agent
        /// The sections already in effect in the active transcript, by key.
        public let shown: [String: String]
        let handle: ScopeHandle

        /// A document, as committed. Defaults to the conversation's.
        public func document<Value>(
            _ document: Document<Value>, of owner: DocumentOwner? = nil, key: String? = nil, asOf entry: EntryID? = nil
        ) async throws -> Value {
            try await handle.document(document, of: owner ?? .conversation(conversationId), key: key, asOf: entry)
        }

        /// The environment built for this request (pi-durable `PromptInput.env`), for example to describe the
        /// working directory; `nil` without one. Valid while the section renders.
        public func environment() async throws -> ExecutionEnv? {
            try await handle.environment()
        }
    }

    public let key: String
    /// Whether the text is wrapped as `<key>\\n…\\n</key>`.
    public let tag: Bool
    let text: String?
    let render: (@Sendable (Input) async throws -> String?)?

    /// A section with fixed text.
    public init(_ key: String, tag: Bool = true, text: String) {
        self.key = key
        self.tag = tag
        self.text = text
        self.render = nil
    }

    /// A section rendered before every request. Returning `nil` omits it. Text that changes on every request,
    /// such as the current time, defeats provider prompt caches.
    public init(_ key: String, tag: Bool = true, render: @escaping @Sendable (Input) async throws -> String?) {
        self.key = key
        self.tag = tag
        self.text = nil
        self.render = render
    }

    var specification: BridgeArguments {
        ["key": key, "tag": tag, "text": text]
    }
}

/// What a hook can do besides its arguments (pi-durable `HookApi`).
public struct HookContext: Sendable {
    public let conversationId: ConversationID
    /// The task asking: a generation, tool, or compaction task.
    public let taskId: TaskID
    /// The harness's models (pi-durable `api.models`), for calling a model from a hook.
    public let models: Models
    let handle: ScopeHandle

    /// A durable value shared by the hooks and the task, stored on first use.
    public func memo<Value: Codable & Sendable>(_ name: String, default candidate: @autoclosure () -> Value) async throws -> Value {
        try await handle.memo(name, default: candidate())
    }

    public func memo<Value: Codable & Sendable>(_ name: String, as type: Value.Type = Value.self) async throws -> Value? {
        try await handle.memo(name, as: type)
    }

    /// A document, as committed. Defaults to the conversation's.
    public func document<Value>(
        _ document: Document<Value>, of owner: DocumentOwner? = nil, key: String? = nil, asOf entry: EntryID? = nil
    ) async throws -> Value {
        try await handle.document(document, of: owner ?? .conversation(conversationId), key: key, asOf: entry)
    }
}

/// What a compaction is about to summarize, for ``Hook/beforeCompact(_:)``.
public struct CompactionRequest: Decodable, Sendable {
    public let reason: CompactionReason
    /// The entries the summary replaces, the head marker first.
    public let entries: [Entry]
    /// Their model context, which the summarizer reads.
    public let messages: [Message]
    /// The first entry kept verbatim.
    public let firstKept: EntryID
    /// Instructions given to ``Conversation/compact(instructions:)``.
    public let instructions: String?
}

/// The outcome of a ``Hook/beforeCompact(_:)`` hook.
public enum CompactionDecision: Sendable {
    /// Don't compact this time.
    case decline
    /// Use this summary instead of asking the model.
    case summary(String)
}

/// Observes or adjusts the built-in generation, tool, and compaction tasks, in the conversations that select the
/// hook's extension (pi-durable `hook`).
public struct Hook: Sendable {
    enum Kind {
        case beforeTool(@Sendable (ToolCall, HookContext) async throws -> ToolDecision)
        case afterTool(@Sendable (ToolCall, ToolResult, HookContext) async throws -> ToolResult?)
        case onYield(@Sendable (AssistantMessage, HookContext) async throws -> [ContentBlock]?)
        case beforeRequest(@Sendable ([Message], HookContext) async throws -> [Message]?)
        case afterResponse(@Sendable (AssistantMessage, HookContext) async throws -> Void)
        case afterTools(@Sendable (EntryID, [EntryID], HookContext) async throws -> Void)
        case beforeCompact(@Sendable (CompactionRequest, HookContext) async throws -> CompactionDecision?)
        /// A hook of a ``TaskType``, by task and hook name.
        case task(String, String, @Sendable (JSONValue, TaskHookContext) async throws -> JSONValue?)

        var name: String {
            switch self {
            case .beforeTool: "beforeTool"
            case .afterTool: "afterTool"
            case .onYield: "onYield"
            case .beforeRequest: "beforeRequest"
            case .afterResponse: "afterResponse"
            case .afterTools: "afterTools"
            case .beforeCompact: "beforeCompact"
            case .task: "task"
            }
        }
    }

    let kind: Kind

    /// Runs before a tool call's intent is recorded: allow it, rewrite its arguments, or block it with a message the
    /// model sees. Throwing blocks the call. A good place to ask the user for approval.
    public static func beforeTool(_ handler: @escaping @Sendable (ToolCall, HookContext) async throws -> ToolDecision) -> Hook {
        Hook(kind: .beforeTool(handler))
    }

    /// Runs after a tool call, before its result is recorded; return a replacement result or `nil` to keep it.
    public static func afterTool(
        _ handler: @escaping @Sendable (ToolCall, ToolResult, HookContext) async throws -> ToolResult?
    ) -> Hook {
        Hook(kind: .afterTool(handler))
    }

    /// Runs on each final answer; return a message to continue the run with it as user input, or `nil` to finish.
    public static func onYield(_ handler: @escaping @Sendable (AssistantMessage, HookContext) async throws -> String?) -> Hook {
        Hook(kind: .onYield { answer, context in try await handler(answer, context).map { [.text($0)] } })
    }

    /// Runs on each final answer; return user content (text and images) to continue the run with it, or `nil` to
    /// finish.
    public static func onYieldContent(
        _ handler: @escaping @Sendable (AssistantMessage, HookContext) async throws -> [ContentBlock]?
    ) -> Hook {
        Hook(kind: .onYield(handler))
    }

    /// Runs before every model request attempt; return replacement messages for that request only, or `nil`.
    /// Messages you return unchanged keep every provider field (signatures, IDs).
    public static func beforeRequest(_ handler: @escaping @Sendable ([Message], HookContext) async throws -> [Message]?) -> Hook {
        Hook(kind: .beforeRequest(handler))
    }

    /// Runs on every terminal provider response, before it is classified.
    public static func afterResponse(_ handler: @escaping @Sendable (AssistantMessage, HookContext) async throws -> Void) -> Hook {
        Hook(kind: .afterResponse(handler))
    }

    /// Runs once every tool of a round is done, with the tool-calling answer and the result entries in call order.
    public static func afterTools(
        _ handler: @escaping @Sendable (_ assistant: EntryID, _ results: [EntryID], HookContext) async throws -> Void
    ) -> Hook {
        Hook(kind: .afterTools(handler))
    }

    /// Runs before a compaction summarizes; decline it, supply your own summary, or return `nil` to let the model
    /// summarize.
    public static func beforeCompact(
        _ handler: @escaping @Sendable (CompactionRequest, HookContext) async throws -> CompactionDecision?
    ) -> Hook {
        Hook(kind: .beforeCompact(handler))
    }
}

extension Hook {
    /// A handler of a hook point that one of your ``TaskType``s defines, run when the task calls
    /// ``TaskRun/hooks(_:arguments:)``. Like pi-durable `hook(task, handlers)` for your own tasks.
    ///
    /// ```swift
    /// Hook.task(payment, "beforeCharge") { arguments, _ in
    ///     arguments["amount"]?.doubleValue ?? 0 > 100 ? ["block": "Needs approval"] : nil
    /// }
    /// ```
    public static func task<Input, State, Result>(
        _ type: TaskType<Input, State, Result>, _ name: String,
        _ handler: @escaping @Sendable (_ arguments: JSONValue, TaskHookContext) async throws -> JSONValue?
    ) -> Hook {
        Hook(kind: .task(type.name, name, handler))
    }

    /// A typed task hook handler: the task's arguments decode as `Arguments`, and the result encodes from `Output`.
    ///
    /// ```swift
    /// Hook.task(payment, "beforeCharge") { (charge: Charge, _) -> Verdict? in
    ///     charge.amount > 100 ? Verdict(block: "Needs approval") : nil
    /// }
    /// ```
    public static func task<Input, Checkpoint, Result, Arguments: Decodable & Sendable, Output: Encodable & Sendable>(
        _ type: TaskType<Input, Checkpoint, Result>, _ name: String,
        _ handler: @escaping @Sendable (_ arguments: Arguments, TaskHookContext) async throws -> Output?
    ) -> Hook {
        Hook(kind: .task(type.name, name) { arguments, context in
            let decoded: Arguments = try arguments.decode()
            return try await handler(decoded, context).map { try JSONValue(encoding: $0) }
        })
    }
}

/// Where a task hook runs.
public struct TaskHookContext: Sendable {
    public let conversationId: ConversationID
    /// The task running the hook.
    public let taskId: TaskID
}

/// The outcome of a ``Hook/beforeTool(_:)`` hook.
public enum ToolDecision: Sendable {
    /// Run the call as requested.
    case allow
    /// Run the call with these arguments instead.
    case rewrite(JSONObject)
    /// Do not run the call; the model sees this message as an error result.
    case block(String)
}

/// Decorates a tool or a section by name, whichever extension provides it (pi-durable `wrapTool` and `wrapSection`).
///
/// ```swift
/// Wrap.tool("get_weather") { call, context, next in
///     let started = Date()
///     var result = try await next(nil)
///     result.details = ["seconds": .number(Date().timeIntervalSince(started))]
///     return result
/// }
/// ```
public struct Wrap: Sendable {
    /// Runs the wrapped tool, with replacement arguments or `nil` for the original ones.
    public typealias ToolNext = @Sendable (JSONObject?) async throws -> ToolResult
    /// Renders the wrapped section.
    public typealias SectionNext = @Sendable () async throws -> String?

    enum Kind {
        case tool(String, ToolWrap)
        case section(String, @Sendable (PromptSection.Input, SectionNext) async throws -> String?)
    }

    /// What a tool wrap changes.
    struct ToolWrap {
        var definition: (@Sendable (inout ToolDefinition) -> Void)?
        var prepareArguments: (@Sendable (JSONValue) -> JSONValue)?
        var execute: (@Sendable (ToolCall, ToolCallContext, ToolNext) async throws -> ToolResult)?
    }

    let kind: Kind

    /// Wraps the execution of the tool named `name`.
    public static func tool(
        _ name: String, _ wrapper: @escaping @Sendable (ToolCall, ToolCallContext, _ next: ToolNext) async throws -> ToolResult
    ) -> Wrap {
        Wrap(kind: .tool(name, ToolWrap(execute: wrapper)))
    }

    /// Wraps the tool named `name`, as pi-durable's `wrapTool` returns a whole new tool: change what the model sees
    /// (description, parameters) and how the harness runs it (replay, execution mode, output limits), repair its
    /// arguments before its own repair step, and wrap its execution.
    ///
    /// ```swift
    /// Wrap.tool("bash", definition: { $0.description += " Prefer pnpm over npm." })
    /// ```
    ///
    /// - Parameters:
    ///   - name: The tool to wrap.
    ///   - definition: Changes the tool's definition. Must be pure: it runs whenever the agent is resolved. Changing
    ///     the name is ignored.
    ///   - prepareArguments: Repairs arguments before the wrapped tool's own `prepareArguments`. Must be pure.
    ///   - execute: Wraps execution; `nil` runs the tool unchanged.
    public static func tool(
        _ name: String,
        definition: (@Sendable (inout ToolDefinition) -> Void)? = nil,
        prepareArguments: (@Sendable (JSONValue) -> JSONValue)? = nil,
        execute: (@Sendable (ToolCall, ToolCallContext, _ next: ToolNext) async throws -> ToolResult)? = nil
    ) -> Wrap {
        Wrap(kind: .tool(name, ToolWrap(definition: definition, prepareArguments: prepareArguments, execute: execute)))
    }

    public static func section(
        _ key: String, _ wrapper: @escaping @Sendable (PromptSection.Input, _ next: SectionNext) async throws -> String?
    ) -> Wrap {
        Wrap(kind: .section(key, wrapper))
    }

    func specification(index: Int) -> BridgeArguments {
        switch kind {
        case .tool(let name, let wrap):
            [
                "index": index, "tool": name, "defines": wrap.definition != nil, "prepares": wrap.prepareArguments != nil,
                "executes": wrap.execute != nil,
            ]
        case .section(let key, _): ["index": index, "section": key]
        }
    }
}

/// A tool's definition as a ``Wrap`` sees and changes it: the pi-ai `Tool` fields and the harness's run options.
public struct ToolDefinition: Codable, Sendable, Hashable {
    /// The tool's name; a wrap cannot change it.
    public let name: String
    public var description: String
    /// The JSON schema of the tool's arguments.
    public var parameters: JSONValue
    public var replay: Tool.Replay?
    public var executionMode: Settings.ToolExecution?
    public var outputLimits: Tool.OutputLimits?
    /// The JSON schema of the tool's structured output.
    public var structuredOutputSchema: JSONValue?
    /// Who may call the tool; `nil` for both the model and other tools.
    public var callers: [Tool.Caller]?
    /// Whether the tool is kept from the model until loaded.
    public var deferred: Bool?
}

/// One of pi-durable's built-in tools, for ``Extension/builtinTools(name:_:images:)``. They work in the call's
/// ``ExecutionEnvironment`` and fail with an error result without one.
public enum BuiltinTool: Sendable {
    /// `read`: reads text files, with offsets and truncation.
    case read
    /// `write`: writes files.
    case write
    /// `edit`: exact text replacements in a file.
    case edit
    /// `bash`: runs a command in the environment's shell, keeping the tail of its output. Needs an environment with a
    /// shell.
    ///
    /// - Parameters:
    ///   - commandPrefix: Lines run before each command, such as activating a virtual environment.
    ///   - prepare: Changes each command before it runs: its script, directory, and environment variables.
    case bash(commandPrefix: String? = nil, prepare: (@Sendable (inout BashExecution, ToolCallContext) async throws -> Void)? = nil)
    /// `powershell`: runs a command through PowerShell (`pwsh`, then `powershell`, or `programs` in order).
    case powerShell(
        commandPrefix: String? = nil, programs: [String]? = nil,
        prepare: (@Sendable (inout BashExecution, ToolCallContext) async throws -> Void)? = nil)

    var prepare: (@Sendable (inout BashExecution, ToolCallContext) async throws -> Void)? {
        switch self {
        case .bash(_, let prepare), .powerShell(_, _, let prepare): prepare
        default: nil
        }
    }

    func specification(index: Int, images: Bool) -> JSONValue {
        switch self {
        case .read: return ["kind": "read", "index": .number(Double(index)), "images": .bool(images)]
        case .write: return ["kind": "write"]
        case .edit: return ["kind": "edit"]
        case .bash(let prefix, let prepare):
            return ["kind": "bash", "index": .number(Double(index)), "commandPrefix": prefix.map(JSONValue.string) ?? .null, "prepares": .bool(prepare != nil)]
        case .powerShell(let prefix, let programs, let prepare):
            return [
                "kind": "powershell", "index": .number(Double(index)), "commandPrefix": prefix.map(JSONValue.string) ?? .null,
                "programs": programs.map { .array($0.map(JSONValue.string)) } ?? .null, "prepares": .bool(prepare != nil),
            ]
        }
    }
}

/// A command a built-in shell tool is about to run (pi-durable `BashExecution`).
public struct BashExecution: Codable, Sendable, Hashable {
    /// The script, with its prefix.
    public var command: String
    /// The working directory.
    public var cwd: String
    /// Environment variables.
    public var env: [String: String]
    /// Whether the host's environment variables are inherited.
    public var inheritEnv: Bool
}

/// Options of ``Extension/codemode(name:_:)`` (pi-durable `CodemodeToolOptions`).
public struct CodemodeOptions: Sendable {
    /// A group of tools by name prefix, such as an MCP server's, for the `codemode` section and tool search.
    public struct Namespace: Encodable, Sendable, Hashable {
        public var name: String
        /// Tool names starting with it belong to the namespace; the longest matching prefix wins.
        public var prefix: String
        public var description: String?
        public var instructions: String?

        public init(_ name: String, prefix: String, description: String? = nil, instructions: String? = nil) {
            self.name = name
            self.prefix = prefix
            self.description = description
            self.instructions = instructions
        }
    }

    public var namespaces: [Namespace]
    /// Estimated tokens the tool declarations in the `codemode` section may use; default 3000.
    public var inlineBudget: Int?
    /// Give scripts `models.*`: the model catalog, classifiers, and image generation; default `true`.
    public var models: Bool?
    /// Interrupt polls a script may use computing without awaiting a tool before it fails as timed out; default
    /// 100,000. On an iPhone 18 Pro, 100,000 is about 40 seconds of computing and 10,000 about 4. A script that ends
    /// otherwise (its deadline passed, or its run was stopped) computes on until its next tool call or the end of this
    /// budget, on its own thread.
    public var interruptBudget: Int?
    /// The most memory a script's VM may allocate, in bytes; past it, allocations fail inside the script as
    /// `InternalError: out of memory`. Default: no limit short of WebAssembly's 4 GiB, which on an iPhone is more than
    /// iOS lets an app use.
    public var memoryLimitBytes: Int?

    public init(
        namespaces: [Namespace] = [], inlineBudget: Int? = nil, models: Bool? = nil, interruptBudget: Int? = nil,
        memoryLimitBytes: Int? = nil
    ) {
        self.namespaces = namespaces
        self.inlineBudget = inlineBudget
        self.models = models
        self.interruptBudget = interruptBudget
        self.memoryLimitBytes = memoryLimitBytes
    }

    /// The bundled `quickjs.wasm`.
    static var quickJSPath: String {
        Bundle.module.url(forResource: "quickjs", withExtension: "wasm")!.path(percentEncoded: false)
    }
}
