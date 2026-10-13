import Foundation
import Testing
@testable import PiDurableKit

/// The values pi-durable sends that Swift decodes in full.
@Suite struct DecodingTests {
    @Test func liveStateKeepsEveryField() throws {
        let json: JSONValue = [
            "generation": ["attempt": 2, "retry": ["at": 1000, "error": "busy"], "deferred": ["pollAt": 2000]],
            "tools": [[
                "callId": "c1", "name": "bash", "status": "running", "output": "tail", "droppedBytes": 10, "droppedLines": 2,
                "diagnostics": [["severity": "warn", "message": "truncated", "code": "trunc"]],
            ]],
            "compactions": [["taskId": 7, "reason": "threshold", "blocking": true, "attempt": 1, "retry": ["at": 3000, "error": "x"]]],
        ]
        let live = try json.decode(as: LiveState.self)
        #expect(live.generation?.attempt == 2)
        #expect(live.generation?.retry?.error == "busy")
        #expect(live.generation?.deferred?.pollAt == Date(timeIntervalSince1970: 2))
        #expect(live.tools[0].droppedBytes == 10)
        #expect(live.tools[0].droppedLines == 2)
        #expect(live.tools[0].diagnostics == [ToolDiagnostic("truncated", severity: .warn, code: "trunc")])
        #expect(live.compactions[0].reason == .threshold)
        #expect(live.compactions[0].retry?.at == Date(timeIntervalSince1970: 3))
    }

    @Test func agentEventsKeepEveryField() throws {
        let snapshot = try ([
            "type": "snapshot", "entries": [], "tools": [], "inbox": [["id": 3, "mode": "steer"]], "agent": [:],
            "usage": ["models": [:], "tools": [:]],
            "generation": ["attempt": 1, "retry": ["at": 5000, "error": "rate limited"]],
            "compactions": [["taskId": 9, "reason": "manual", "blocking": false, "attempt": 0]],
        ] as JSONValue).decode(as: AgentEvent.self)
        guard case .snapshot(let value) = snapshot else {
            Issue.record("Expected a snapshot, got \(snapshot)")
            return
        }
        #expect(value.generation?.retry?.error == "rate limited")
        #expect(value.compactions.map(\.taskId) == [9])
        #expect(value.inbox.first?.mode == .steer)

        let update = try ([
            "type": "tool_execution_update", "toolCallId": "c", "toolName": "t",
            "diagnostics": [["severity": "info", "message": "spilled"]],
        ] as JSONValue).decode(as: AgentEvent.self)
        guard case .toolExecutionUpdate(_, _, _, let diagnostics) = update else {
            Issue.record("Expected a tool update, got \(update)")
            return
        }
        #expect(diagnostics?.first?.message == "spilled")

        let poll = try (["type": "deferred_poll", "pollAt": 4000] as JSONValue).decode(as: AgentEvent.self)
        #expect(poll == .deferredPoll(pollAt: Date(timeIntervalSince1970: 4)))
    }

    @Test func inspectionStates() throws {
        let record: JSONValue = [
            "id": 1, "conversationId": 1, "kind": "x", "version": 1, "input": nil, "background": false,
            "abortRequested": false, "state": ["status": "pending", "checkpoint": ["phase": "a"]],
        ]
        let inspection = try ([
            "scheduling": "paused", "submissions": [],
            "tasks": [
                ["record": record, "state": ["kind": "ready", "migrates": true]],
                ["record": record, "state": ["kind": "blocked", "reason": "migration_failed", "error": ["message": "bad"]]],
            ],
        ] as JSONValue).decode(as: HarnessInspection.self)
        #expect(inspection.scheduling == .paused)
        #expect(inspection.tasks[0].state == .ready(migrates: true))
        #expect(inspection.tasks[1].state == .blocked(reason: "migration_failed", error: "bad"))
        #expect(inspection.tasks[1].blockedReason == "migration_failed")
    }

    @Test func errorsKeepTheirFields() {
        let busy = PiDurableError(javaScriptJSON: #"{"name":"ConversationBusy","message":"busy","conversationId":4}"#)
        guard case .conversationBusy(let id) = busy else {
            Issue.record("Expected conversationBusy, got \(busy)")
            return
        }
        #expect(id == 4)
        let file = PiDurableError(javaScriptJSON: #"{"name":"FileError","message":"gone","code":"not_found","path":"/a"}"#)
        guard case .file("not_found", "gone", "/a") = file else {
            Issue.record("Expected a file error, got \(file)")
            return
        }
        let other = PiDurableError(javaScriptJSON: #"{"name":"TypeError","message":"x","code":"E1"}"#)
        guard case .javaScript("TypeError", "x", _, "E1") = other else {
            Issue.record("Expected a JavaScript error with a code, got \(other)")
            return
        }
        guard case .jsonlCorrupted = PiDurableError(javaScriptJSON: #"{"name":"JsonlCorruptionError","message":"bad line"}"#) else {
            Issue.record("Expected jsonlCorrupted")
            return
        }
    }

    @Test func agentStateIsTyped() throws {
        let state = try (["extensions": ["add": ["a"]], "tools": ["remove": ["bash"]]] as JSONValue).decode(as: AgentState.self)
        #expect(state.extensions == .edit(add: ["a"], remove: []))
        #expect(state.tools == .remove(["bash"]))
        let only = try (["extensions": ["x", "y"], "tools": ["read"]] as JSONValue).decode(as: AgentState.self)
        #expect(only.extensions == .only(["x", "y"]))
        #expect(only.tools == .only(["read"]))
    }
}

/// Transcript writes and transaction reads beyond the inbox.
@Suite struct TranscriptTests {
    @Test func headMarkersAndContextEdits() async throws {
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        let first = try await root.commit { tx in
            try await tx.append(EntryDraft(kind: "app.note", model: [.user(UserMessage(content: [.text("first")]))]), to: root.id)
        }
        let second = try await root.commit { tx in
            try await tx.append(EntryDraft(kind: "app.note", model: [.user(UserMessage(content: [.text("second")]))]), to: root.id)
        }
        // Omit the first entry's messages, and replace the second's.
        let edit = try await root.commit { tx in
            try await tx.append(
                EntryDraft(
                    kind: "app.edit",
                    edits: [.omit(first.id), .replace(second.id, with: [.user(UserMessage(content: [.text("edited")]))])]),
                to: root.id)
        }
        #expect(edit.edits?.count == 2)
        #expect(try await root.context().messages.map(\.text) == ["edited"])

        // A head marker starts a new context at itself.
        let marker = try await root.commit { tx in
            try await tx.append(
                EntryDraft(kind: "app.restart", model: [.user(UserMessage(content: [.text("fresh")]))], head: .itself), to: root.id)
        }
        let context = try await root.context()
        #expect(context.head?.id == marker.id)
        #expect(context.messages.map(\.text) == ["fresh"])
        #expect(context.contributions.count == context.entries.count)
        #expect(try await root.commit { tx in try await tx.latestHeadMarker(in: root.id) }?.id == marker.id)

        // A head marker can keep entries from an earlier one on.
        let kept = try await root.commit { tx in
            try await tx.append(EntryDraft(kind: "app.summary", head: .entry(marker.id)), to: root.id)
        }
        #expect(kept.head == marker.id)
    }

    @Test func transactionReadsAndRawSubmissions() async throws {
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        let written = try await root.write(EntryDraft(kind: "app.note"), requestId: "note-1").wait()
        let found = try await root.commit { tx in try await tx.submission(in: root.id, requestId: "note-1") }
        #expect(found?.id == written.id)

        var collected: [EntryID] = []
        for index in 0..<4 {
            collected.append(try await root.commit { tx in try await tx.append(EntryDraft(kind: "app.n", data: .number(Double(index))), to: root.id) }.id)
        }
        let ids = collected
        let range = try await root.commit { tx in try await tx.entries(in: root.id, from: ids[1], through: ids[2]) }
        #expect(range.items.map(\.id) == [ids[2], ids[1]])

        // Raw admission: create, place, and settle a submission yourself.
        let raw = try await root.commit { tx in
            try await tx.createSubmission(SubmissionDraftRecord(conversationId: root.id, type: .input, requestId: "raw"))
        }
        #expect(raw.status == .queued)
        let entry = try await root.commit { tx in
            try await tx.append(EntryDraft(kind: .user, model: [.user(UserMessage(content: [.text("raw")]))]), to: root.id)
        }
        try await root.commit { tx in try await tx.placeSubmission(raw.id, at: entry.id) }
        #expect(try await setup.harness.submission(raw.id)?.status().status == .placed(entry: entry.id))
        try await root.commit { tx in try await tx.settleSubmission(raw.id, .unanswered(reason: "app", detail: "why")) }
        #expect(try await setup.harness.submission(raw.id)?.status().status == .unanswered(entry: entry.id, reason: "app", detail: "why"))
    }

    @Test func submissionsByIDAndConversation() async throws {
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        let other = try await setup.harness.createConversation()
        #expect(try await setup.harness.submission(SubmissionID(999_999)) == nil)
        let submission = try await root.write(EntryDraft(kind: "app.note"))
        _ = try await submission.wait()
        #expect(try await setup.harness.abortSubmission(submission.id, in: other.id) == .notFound)
        #expect(try await setup.harness.abortSubmission(submission.id, in: root.id) == .settled)
    }

    @Test func recordsEntriesAndConversationLists() async throws {
        let setup = try await FauxSetup.make()
        let root = try await setup.root()
        let entry = try await root.commit { tx in try await tx.append(EntryDraft(kind: "app.note"), to: root.id) }
        let fork = try await root.fork(at: entry.id)
        #expect(try await fork.record().parent?.conversationId == root.id)
        #expect(try await root.entry(entry.id)?.kind == "app.note")
        #expect(try await root.entry(EntryID(999_999)) == nil)
        let page = try await setup.harness.conversations()
        #expect(page.items.map(\.id).contains(fork.id))
        #expect(page.items.map(\.id).contains(root.id))
    }

    @Test func typedBuiltinEntries() async throws {
        let setup = try await FauxSetup.make()
        try await setup.faux.append(.text("Hi"))
        let root = try await setup.root()
        _ = try await ask(root, "Hello")
        let entries = try await root.view().entries
        #expect(entries.contains { $0.is(.assistant) })
        #expect(entries.contains { $0.is(.user) })

        let tool = Tool("noted", description: "Noted") { (call: ToolCallContext) in
            try await call.diagnostic(ToolDiagnostic("a remark", code: "remark"))
            return "ok"
        }
        try await setup.harness.install(Extension("noted", tools: [tool]))
        try await setup.faux.append(.toolCall("noted", [:]))
        try await setup.faux.append(.text("done"))
        _ = try await ask(root, "Note")
        let result = try #require(try await root.view().entries.first { $0.is(.toolResult) })
        #expect(result.data(as: .toolResult)?.diagnostics.map(\.code) == ["remark"])
    }
}

/// Conversations owned by tasks, built-in documents, and the rest of the conversation surface.
@Suite struct ConversationSurfaceTests {
    @Test func taskOwnedConversationsFromTheHarness() async throws {
        let created = Mutex<ConversationID?>(nil)
        let spawn = Tool("spawn", description: "Spawn") { (call: ToolCallContext) in
            let child = try await call.harness.createConversation(ownedBy: call.taskId)
            created.update { $0 = child.id }
            let handle = try #require(try await call.conversation(child.id))
            _ = try await handle.submit([.text("from"), .text(" parent")])
            return "spawned"
        }
        let setup = try await FauxSetup.make(extensions: [Extension("spawn", tools: [spawn])])
        try await setup.faux.respond { messages, _ in
            let last = messages.last?.text ?? ""
            if last == "Go" { return FauxResponse([.toolCall("spawn", [:])]) }
            return .text("ok")
        }
        let root = try await setup.root()
        _ = try await withTimeout { try await ask(root, "Go") }
        let child = try #require(created.get())
        let record = try await #require(try await setup.harness.conversation(child)).record()
        #expect(record.owner?.conversationId == root.id)
        let owned = try await setup.harness.conversations(ownedBy: record.owner?.taskId)
        #expect(owned.items.map(\.id) == [child])
    }

    @Test func builtinDocuments() async throws {
        let setup = try await FauxSetup.make()
        try await setup.faux.append(.text("Answer"))
        let root = try await setup.root(AgentChange(instructions: "first"))
        let marker = try await root.commit { tx in try await tx.append(EntryDraft(kind: "app.marker"), to: root.id) }
        try await root.configure(AgentChange(instructions: "second"))
        _ = try await ask(root, "Hello")

        #expect(try await root.agentState().instructions == "second")
        #expect(try await root.agentState(asOf: marker.id).instructions == "first")
        let session = try #require(try await root.providerSessionId())
        #expect(try await root.view().providerSessionId == session)
        #expect(try await root.usage().models.isEmpty == false)
        #expect(try await root.inbox().isEmpty)
        #expect(try await root.liveState().run == nil)
    }

    @Test func isConfigured() async throws {
        let setup = try await FauxSetup.make()
        #expect(try await setup.models.isConfigured(setup.faux.id))
        let models = Models(builtinProviders: true)
        #expect(try await models.isConfigured(.anthropic) == false)
        try await models.setAPIKey("sk-test", for: .anthropic)
        #expect(try await models.isConfigured(.anthropic))
    }
}

/// Registry, settings, sections, hooks, and wraps.
@Suite struct ExtensionSurfaceTests {
    @Test func registryAndSettings() async throws {
        let seen = Mutex<(RegistrySnapshot?, Settings?)>((nil, nil))
        let probe = Tool("probe", description: "Probe") { (call: ToolCallContext) in
            let registry = try await call.registry()
            seen.update { $0.0 = registry }
            return "ok"
        }
        let setup = try await FauxSetup.make(
            extensions: [Extension("probe", tools: [probe], sections: [PromptSection("hello", text: "Hi")])],
            settings: Settings(retry: .init(maxRetries: 7)))
        let registry = try await setup.harness.registry()
        #expect(registry.extension("probe")?.tools.map(\.name) == ["probe"])
        #expect(registry.extension("probe")?.sections.map(\.key) == ["hello"])
        #expect(registry.tasks.map(\.name).contains("pi.generation"))

        let resolved = try await setup.harness.resolvedSettings()
        #expect(resolved.retry?.maxRetries == 7)
        #expect(resolved.retry?.baseDelay == .milliseconds(2000))
        #expect(resolved.toolExecution == .parallel)
        let defaults = try await Runtime.shared.defaultSettings()
        #expect(defaults.compaction?.reserveTokens == 16384)
        #expect(defaults.contextRetention == .milliseconds(600_000))

        try await setup.faux.append(.toolCall("probe", [:]))
        try await setup.faux.append(.text("done"))
        let root = try await setup.root(AgentChange(instructions: "Be brief"))
        _ = try await ask(root, "Probe")
        #expect(seen.get().0?.extension("probe") != nil)
        let agent = try await root.agent()
        #expect(agent.sections.map(\.key) == ["hello", PromptSection.instructionsKey])
    }

    @Test func taskPhasesSeeSettingsAndRegistry() async throws {
        let seen = Mutex<(Int?, Bool)>((nil, false))
        let probe = TaskType<Empty, At, String>("test.probe", version: 1, initial: { _ in At(phase: "run") }, abort: abortTask) {
            Phase("run") { run in
                let settings = try await run.settings()
                let registry = try await run.registry()
                let environment = try await run.environment()
                seen.update { $0 = (settings.retry?.maxRetries, registry.extension("tasks") != nil && environment == nil) }
                try await run.commit { _, _ in .completed("ok") }
            }
        }
        let setup = try await FauxSetup.make(extensions: [Extension("tasks", tasks: [probe.any])], settings: Settings(retry: .init(maxRetries: 5)))
        let root = try await setup.root()
        let id = try await root.commit { tx in try await tx.createTask(probe, input: Empty()) }
        _ = try await withTimeout { try await setup.harness.waitForTask(id) }
        #expect(seen.get().0 == 5)
        #expect(seen.get().1)
    }

    @Test func onYieldContinuesWithContent() async throws {
        let once = Mutex(false)
        let keepGoing = Extension("keep-going") {
            Hook.onYieldContent { _, _ in
                if once.get() { return nil }
                once.update { $0 = true }
                return [.text("Continue"), .text(" please")]
            }
        }
        let setup = try await FauxSetup.make(extensions: [keepGoing])
        try await setup.faux.append(.text("first"))
        try await setup.faux.append(.text("second"))
        let root = try await setup.root()
        let answer = try await withTimeout { try await ask(root, "Start") }
        #expect(answer.text == "second")
        #expect(try await root.view().messages.map(\.text).contains("Continue please"))
    }

    @Test func wrapsChangeToolDefinitions() async throws {
        let echo = Tool("echo", description: "Echo", parameters: .object(["text": .string()])) { (args: [String: String], _) in
            args["text"] ?? ""
        }
        let wrap = Extension("wrap") {
            Wrap.tool(
                "echo",
                definition: { $0.description += " Loudly." },
                prepareArguments: { raw in
                    guard case .object(var object) = raw, let text = object["text"]?.stringValue else { return raw }
                    object["text"] = .string(text.uppercased())
                    return .object(object)
                })
        }
        let offered = Mutex<[OfferedTool]>([])
        let inspect = Tool("inspect", description: "Inspect") { (call: ToolCallContext) in
            let tools = try await call.tools()
            offered.update { $0 = tools }
            return "ok"
        }
        let setup = try await FauxSetup.make(extensions: [Extension("echo", tools: [echo, inspect]), wrap])
        try await setup.faux.append(.toolCall("inspect", [:]))
        try await setup.faux.append(.toolCall("echo", ["text": "hi"]))
        try await setup.faux.append(.text("done"))
        let root = try await setup.root()
        _ = try await withTimeout { try await ask(root, "Go") }
        #expect(offered.get().first { $0.name == "echo" }?.description == "Echo Loudly.")
        let results = try await root.view().entries.compactMap(\.toolResult)
        #expect(results.last?.text == "HI")
    }

    @Test func rawOutputAndOutputWindow() async throws {
        let window = Mutex<OutputWindow?>(nil)
        let tail = Tool("tail", description: "Tail") { (call: ToolCallContext) in
            window.update { $0 = call.outputWindow }
            call.output(Data("bytes ".utf8))
            call.output("and text", skipped: nil)
            return ToolResult.streamedOutput
        }.limitingOutput(.init(retain: .tail))
        let setup = try await FauxSetup.make(extensions: [Extension("tail", tools: [tail])])
        try await setup.faux.append(.toolCall("tail", [:]))
        try await setup.faux.append(.text("done"))
        let root = try await setup.root()
        _ = try await withTimeout { try await ask(root, "Go") }
        #expect(window.get() != nil)
        #expect(try await root.view().entries.compactMap(\.toolResult).first?.text.hasPrefix("bytes and text") == true)
    }
}

/// Execution environments used from Swift, implemented in Swift, and with a shell.
@Suite struct ExecutionEnvTests {
    @Test func hostUsesAConversationsEnvironment() async throws {
        let directory = temporaryDirectory()
        let setup = try await FauxSetup.make(extensions: [.codingTools()])
        _ = setup
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        let harness = try await Harness.open(models: models, environment: .directory(directory))
        let root = try await harness.root(agent: AgentChange(model: faux.model, cwd: "/work"))
        let env = try #require(try await harness.environment(for: root.id))
        #expect(env.cwd == "/work")
        try await env.createDirectory("/work", recursive: true)
        try await env.write("one\ntwo\nthree\n", to: "notes.txt")
        #expect(try await env.readText("/work/notes.txt") == "one\ntwo\nthree\n")
        #expect(try await env.readLines("notes.txt", maxLines: 2) == ["one", "two"])
        #expect(try await env.exists("notes.txt"))
        try await env.append(Data("four\n".utf8), to: "notes.txt")
        #expect(try await env.fileInfo("notes.txt").size == 19)
        #expect(try await env.listDirectory("/work").map(\.name) == ["notes.txt"])

        let reader = try await env.openBinaryReader("notes.txt")
        #expect(try await reader.read(offset: 4, length: 3) == Data("two".utf8))
        #expect(try await reader.scanLines(from: 1, to: 2).newlines == 4)
        try await reader.close()
        let lines = try await env.openLineReader("notes.txt")
        #expect(try await lines.next()?.text == "one")
        try await lines.close()
        let pages = try await env.openDirectoryReader("/work")
        #expect(try await pages.next().entries.count == 1)
        try await pages.close()

        try await env.move("notes.txt", to: "moved.txt")
        #expect(try await env.exists("notes.txt") == false)
        let temporary = try await env.createTemporaryFile(prefix: "x", suffix: ".txt")
        #expect(temporary.hasSuffix(".txt"))
        try await env.remove("moved.txt")
        do {
            _ = try await env.readText("missing.txt")
            Issue.record("Expected a failure")
        } catch PiDurableError.file(let code, _, let path) {
            #expect(code == "not_found")
            #expect(path == "/work/missing.txt")
        }
        await #expect(throws: PiDurableError.self) { try await env.run(.script("true")) }
        try await harness.close()
    }

    @Test func watchingFiles() async throws {
        let directory = temporaryDirectory()
        let setup = try await FauxSetup.make()
        _ = setup
        let models = Models(builtinProviders: false)
        let harness = try await Harness.open(models: models, environment: .directory(directory))
        let root = try await harness.root()
        let env = try #require(try await harness.environment(for: root.id))
        let changes = env.watch([WatchTarget("/", recursive: true)])
        let first = Task { () -> FileChange? in
            for try await change in changes { return change }
            return nil
        }
        try await Task.sleep(for: .milliseconds(300))
        try await env.write("hi", to: "/new.txt")
        let change = try await withTimeout { try await first.value }
        #expect(change == .paths(["/", "/new.txt"]) || change == .paths(["/new.txt"]))
        try await harness.close()
    }

    @Test func toolsTasksAndSectionsReachTheEnvironment() async throws {
        let filesystem = MemoryFileSystem()
        let seen = Mutex<[String]>([])
        let look = Tool("look", description: "Look") { (call: ToolCallContext) in
            let env = try #require(try await call.environment())
            try await env.write("from tool", to: "/tool.txt")
            return try await env.readText("/tool.txt")
        }
        let section = PromptSection("files") { input in
            let env = try await input.environment()
            let names = try await env?.listDirectory("/").map(\.name) ?? []
            seen.update { $0.append(names.joined(separator: ",")) }
            return nil
        }
        let setup = try await FauxSetup.make()
        _ = setup
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        let harness = try await Harness.open(
            models: models, extensions: [Extension("look", tools: [look], sections: [section]), .codingTools()],
            environment: .custom(filesystem))
        try await faux.append(.toolCall("look", [:]))
        try await faux.append(.toolCall("write", ["path": "/written.md", "content": "# Hi"]))
        try await faux.append(.toolCall("read", ["path": "/written.md"]))
        try await faux.append(.text("done"))
        let root = try await harness.root(agent: AgentChange(model: faux.model))
        _ = try await withTimeout { try await ask(root, "Go") }
        let results = try await root.view().entries.compactMap(\.toolResult)
        #expect(results.map(\.isError) == [false, false, false])
        #expect(results[0].text == "from tool")
        #expect(results[2].text.contains("# Hi"))
        #expect(await filesystem.files()["/written.md"] == "# Hi")
        #expect(seen.get().last?.contains("written.md") == true)
        try await harness.close()
    }

    @Test func jsonlStorageOnACustomFileSystem() async throws {
        let filesystem = MemoryFileSystem()
        let notes = Document("test.notes", scope: .session, initial: FileNote())
        do {
            let session = try await Session.open(.jsonl(in: filesystem, directory: "/store"))
            try await session.update(notes) { $0.text = "persisted" }
            try await session.close()
        }
        #expect(await filesystem.files().keys.contains { $0.hasPrefix("/store/") })
        let session = try await Session.open(.jsonl(in: filesystem, directory: "/store"))
        #expect(try await session.document(notes).text == "persisted")
        try await session.close()
    }

    @Test func environmentConformanceWithoutAShell() async throws {
        let results = try await Runtime.shared.runEnvironmentConformance(symlinks: false) { .custom(MemoryFileSystem()) }
        #expect(results.count > 10)
        // Every case passes except those that run commands, which need a shell.
        let failures = results.filter { !$0.passed && !$0.name.contains("exec") }
        #expect(failures.map { "\($0.name): \($0.failure ?? "")" } == [])
    }

    #if os(macOS)
    @Test func environmentConformanceOfTheSandboxWithAShell() async throws {
        let results = try await Runtime.shared.runEnvironmentConformance { .directory(temporaryDirectory(), shell: true) }
        #expect(results.count > 10)
        #expect(results.filter { !$0.passed }.map { "\($0.name): \($0.failure ?? "")" } == [])
    }
    #endif

    #if os(macOS)
    @Test func localShell() async throws {
        let directory = temporaryDirectory()
        let models = Models(builtinProviders: false)
        let harness = try await Harness.open(models: models, environment: .directory(directory, shell: true))
        let root = try await harness.root()
        let env = try #require(try await harness.environment(for: root.id))
        let output = Mutex("")
        let result = try await env.run(.script("echo hello; echo oops >&2; exit 3")) { chunk in
            output.update { $0 += "\(chunk.stream.rawValue):\(chunk.text)" }
        }
        #expect(result.exitCode == 3)
        #expect(output.get().contains("stdout:hello"))
        #expect(output.get().contains("stderr:oops"))
        let argv = try await env.run(.argv(["pwd"])) { chunk in output.update { $0 = chunk.text } }
        #expect(argv.exitCode == 0)
        #expect(output.get().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(directory.lastPathComponent))
        do {
            try await env.run(.script("sleep 5"), timeout: 0.2)
            Issue.record("Expected a timeout")
        } catch PiDurableError.execution(let code, _, _) {
            #expect(code == "timeout")
        }
        let spilled = try await env.run(.script("seq 1 100"), spill: .init(afterBytes: 1_000_000, afterLines: 10))
        let spillPath = try #require(spilled.spillPath)
        #expect(try await env.readLines(spillPath).count == 100)
        try await harness.close()
    }

    @Test func bashToolWithPrepare() async throws {
        let directory = temporaryDirectory()
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        let shell = Extension.builtinTools(name: "shell", [
            .read,
            .bash(commandPrefix: "export GREETING=hi", prepare: { execution, _ in execution.env["NAME"] = "swift" }),
        ])
        let harness = try await Harness.open(models: models, extensions: [shell], environment: .local)
        let root = try await harness.root(agent: AgentChange(model: faux.model, cwd: directory.path(percentEncoded: false)))
        #expect(try await root.agent().tools == ["read", "bash"])
        try await faux.append(.toolCall("bash", ["command": "echo $GREETING $NAME; pwd"]))
        try await faux.append(.text("done"))
        _ = try await withTimeout { try await ask(root, "Run") }
        let result = try #require(try await root.view().entries.compactMap(\.toolResult).first)
        #expect(result.isError == false)
        #expect(result.text.contains("hi swift"))
        #expect(result.text.contains(directory.lastPathComponent))
        try await harness.close()
    }

    @Test func codingToolsWithShell() async throws {
        #expect(Extension.codingTools(shell: true).builtin?.tools.count == 4)
    }
    #endif
}

/// Plain sessions, custom storage, commit operations, and conformance.
@Suite struct SessionTests {
    @Test func plainSessions() async throws {
        let preferences = Document("test.sessionPreferences", scope: .session, initial: Preferences())
        let session = try await Session.open()
        let commits = session.commits()
        let closing = Task { try await session.closing() }
        try await session.update(preferences) { $0.theme = "dark" }
        #expect(try await session.document(preferences).theme == "dark")
        var iterator = commits.makeAsyncIterator()
        #expect(try await iterator.next() != nil)
        let conversation = try await session.commit { tx in try await tx.createConversation() }
        #expect(conversation.owner == nil)
        try await session.close()
        try await withTimeout { try await closing.value }
    }

    @Test func applyingCommitOperations() async throws {
        let notes = Document("test.applyNotes", scope: .session, initial: Preferences())
        let session = try await Session.open()
        try await session.update(notes) { $0.nested.values = [1] }
        let commits = session.commits()
        var iterator = commits.makeAsyncIterator()
        let before = try JSONValue(encoding: try await session.document(notes))
        try await session.update(notes) {
            $0.nested.values.append(2)
            $0.theme = "dark"
        }
        let publication = try #require(try await iterator.next())
        guard case .document(let change)? = publication.changes.first(where: { if case .document = $0 { true } else { false } }) else {
            Issue.record("Expected a document change")
            return
        }
        let after = try await Runtime.shared.applyOperations(change.ops, to: before)
        #expect(try after.decode(as: Preferences.self) == Preferences(theme: "dark", nested: .init(values: [1, 2])))
        try await session.close()
    }

    @Test func storageConformanceOnYourOwnDatabase() async throws {
        let results = try await Runtime.shared.runStorageConformance {
            .sqlite(database: try TestSQLiteDatabase(path: temporaryDirectory().appending(path: "c.sqlite").path(percentEncoded: false)))
        }
        #expect(results.count > 10)
        #expect(results.filter { !$0.passed }.map { "\($0.name): \($0.failure ?? "")" } == [])
    }

    @Test func customStorageReceivesCalls() async throws {
        let storage = RecordingStorage()
        let session = try await Session.open(.custom(storage))
        let notes = Document("test.customNotes", scope: .session, initial: FileNote())
        #expect(try await session.document(notes) == FileNote())
        try await session.close()
        let operations = await storage.operations
        #expect(operations.contains("findDocument"))
        #expect(operations.contains("close"))
    }
}

/// A ``CustomStorage`` that holds nothing and records which operations it served.
actor RecordingStorage: CustomStorage {
    var operations: [String] = []
    private var nextID = 1

    private func record(_ operation: String) { operations.append(operation) }
    private let empty: JSONValue = ["items": []]

    func commit(_ writes: [JSONValue]) async throws -> Int { record("commit"); return 1 }
    func mintId() async throws -> Int { record("mintId"); defer { nextID += 1 }; return nextID }
    func conversation(_ id: Int) async throws -> JSONValue? { record("conversation"); return nil }
    func scanConversations(_ query: JSONValue, limit: Int, cursor: JSONValue?) async throws -> JSONValue { record("scanConversations"); return empty }
    func entry(_ id: Int, visibleFrom conversationId: Int?) async throws -> JSONValue? { record("entry"); return nil }
    func findLatestHeadMarker(in conversationId: Int, atOrBefore entryId: Int?) async throws -> JSONValue? { record("findLatestHeadMarker"); return nil }
    func scanEntries(_ query: JSONValue, limit: Int, cursor: JSONValue?) async throws -> JSONValue { record("scanEntries"); return empty }
    func task(_ id: Int) async throws -> JSONValue? { record("task"); return nil }
    func scanTasks(_ query: JSONValue, limit: Int, cursor: JSONValue?) async throws -> JSONValue { record("scanTasks"); return empty }
    func submission(_ id: Int) async throws -> JSONValue? { record("submission"); return nil }
    func scanSubmissions(_ query: JSONValue, limit: Int, cursor: JSONValue?) async throws -> JSONValue { record("scanSubmissions"); return empty }
    func submission(in conversationId: Int, requestId: String) async throws -> JSONValue? { record("submissionByRequest"); return nil }
    func findDocument(_ address: JSONValue, at point: JSONValue) async throws -> JSONValue? { record("findDocument"); return nil }
    func document(_ id: Int, at point: JSONValue) async throws -> JSONValue? { record("document"); return nil }
    func scanDocuments(_ query: JSONValue, limit: Int, cursor: JSONValue?) async throws -> JSONValue { record("scanDocuments"); return empty }
    func close() async throws { record("close") }
}
