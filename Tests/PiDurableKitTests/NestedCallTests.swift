import Foundation
import Testing
@testable import PiDurableKit

/// A JavaScript tool, to call from a Swift one.
private let shoutSource = """
    const { defineExtension, defineTool } = require("@earendil-works/pi-durable");
    const { Type } = require("@earendil-works/pi-ai");
    module.exports = defineExtension({
        name: "shout",
        tools: [defineTool({
            name: "shout", description: "Shout a word", parameters: Type.Object({ word: Type.String() }),
            execute: async (args) => ({ output: [{ type: "text", text: args.word.toUpperCase() + "!" }] }),
        })],
    });
    """

private struct Word: Codable, Sendable { var word: String }
private struct Items: Codable, Sendable { var items: [String] }

/// Tools to call: one returning text, one streaming output with details and a diagnostic, one that throws, and one
/// whose arguments need repairing.
private let calleeTools: [Tool] = [
    Tool("echo", description: "Echo a word", parameters: .object(["word": .string("The word")])) { (args: Word, _) in
        "echo \(args.word)"
    },
    Tool("stream", description: "Stream output") { call -> ToolResult in
        call.output("one ")
        call.output("two")
        try await call.details(["step": 2])
        try await call.diagnostic(ToolDiagnostic("Streamed twice", code: "note"))
        return .streamedOutput
    },
    Tool("broken", description: "Always throws") { _ -> String in
        throw PiDurableError.runtime("The broken tool broke")
    },
    Tool("join", description: "Join items", parameters: .object(["items": .array(of: .string)])) { (args: Items, _) in
        args.items.joined(separator: "+")
    }.preparingArguments { raw in
        guard let text = raw["items"]?.stringValue, let data = text.data(using: .utf8),
            let items = try? JSONDecoder().decode([String].self, from: data)
        else { return raw }
        return ["items": .array(items.map(JSONValue.string))]
    },
]

@Suite struct NestedCallTests {
    /// Runs `body` as the tool `caller` in one model turn, and returns what the caller's result shows.
    private func run(
        offering tools: AgentChange.Tools? = nil, _ body: @escaping @Sendable (ToolCallContext) async throws -> ToolResult
    ) async throws -> (result: ToolResultMessage, setup: FauxSetup, root: Conversation) {
        let caller = Tool("caller", description: "Calls other tools") { call -> ToolResult in try await body(call) }
        let setup = try await FauxSetup.make(extensions: [
            Extension("caller", tools: [caller]),
            Extension("callees", tools: calleeTools),
            Extension("shout", javaScript: shoutSource),
        ])
        try await setup.faux.append(.toolCall("caller", [:]))
        try await setup.faux.append(.text("Done"))
        let root = try await setup.root(AgentChange(tools: tools))
        _ = try await withTimeout { try await ask(root, "Call") }
        let result = try #require(try await root.view().entries.first { $0.kind == .toolResult }?.toolResult)
        return (result, setup, root)
    }

    @Test func listsTheOfferedToolsWithTheirSchemas() async throws {
        let seen = Mutex<[OfferedTool]>([])
        _ = try await run { call in
            seen.set(try await call.tools())
            return "ok"
        }
        let tools = seen.get()
        #expect(tools.map(\.name) == ["caller", "echo", "stream", "broken", "join", "shout"])
        let echo = try #require(tools.first { $0.name == "echo" })
        #expect(echo.description == "Echo a word")
        #expect(echo.extension == "callees")
        #expect(echo.parameters["properties"]?["word"]?["type"] == "string")
        #expect(tools.first { $0.name == "shout" }?.extension == "shout")
    }

    @Test func callsSwiftAndJavaScriptToolsInParallel() async throws {
        let (result, _, root) = try await run { call in
            async let echo = call.executeTool("echo", arguments: Word(word: "hi"))
            async let shout = call.executeTool("shout", arguments: ["word": "hey"])
            let results = try await [echo, shout]
            return .text(results.map(\.text).joined(separator: ", "))
        }
        #expect(result.text == "echo hi, HEY!")
        // Nested calls return to their caller instead of the transcript: one tool result.
        #expect(try await root.view().entries.filter { $0.kind == .toolResult }.count == 1)
    }

    @Test func reportsGoIntoTheNestedResult() async throws {
        let called = Mutex<NestedToolResult?>(nil)
        let (result, _, _) = try await run { call in
            called.set(try await call.executeTool("stream"))
            return "caller's own result"
        }
        let streamed = try #require(called.get())
        #expect(streamed.structuredOutput == "one two")
        #expect(streamed.details?["step"] == 2)
        #expect(streamed.diagnostics.map(\.code) == ["note"])
        #expect(result.text == "caller's own result")
        #expect(result.details == nil)
    }

    @Test func repairsAndValidatesArgumentsAsTheHarnessDoes() async throws {
        let results = Mutex<[NestedToolResult]>([])
        _ = try await run { call in
            results.set([
                try await call.executeTool("join", arguments: ["items": #"["a","b"]"#]),
                try await call.executeTool("echo", arguments: ["word": 42]),
                try await call.executeTool("echo", arguments: [:]),
                try await call.executeTool("broken"),
            ])
            return "ok"
        }
        let (join, coerced, missing, broken) = try #require(results.get().count == 4 ? results.get() : nil).splat
        #expect(join.text == "a+b")
        // pi-ai's validation coerces a number to the schema's string.
        #expect(coerced.text == "echo 42")
        #expect(missing.isError)
        #expect(broken.isError)
        #expect(broken.diagnostics.contains { $0.message.contains("The broken tool broke") })
    }

    @Test func onlyCallableToolsCanBeCalled() async throws {
        let outcome = Mutex<NestedToolResult?>(nil)
        let offered = Mutex<([String], [String])>(([], []))
        _ = try await run(offering: .only(["caller", "echo"])) { call in
            offered.set((try await call.tools().map(\.name), try await call.callableTools().map(\.name)))
            outcome.set(try await call.executeTool("shout", arguments: ["word": "hey"]))
            return "ok"
        }
        #expect(offered.get().0 == ["caller", "echo"])
        #expect(offered.get().1 == ["caller", "echo"])
        #expect(outcome.get()?.isError == true)
    }

    @Test func deprecatedCallToolStillWorks() async throws {
        let (result, _, _) = try await run { call in
            let echoed = try await call.callTool("echo", arguments: Word(word: "hi"))
            return .text(echoed.output?.compactMap(\.text).joined() ?? "")
        }
        #expect(result.text == "echo hi")
    }
}

private extension Array {
    var splat: (Element, Element, Element, Element) { (self[0], self[1], self[2], self[3]) }
}
