// Apple Foundation Models as a pi-ai provider: Swift runs each request in a `LanguageModelSession` over the app's
// `LanguageModel` (the on-device system model, Private Cloud Compute, or any other), and this module turns what Swift
// reports into pi-ai's assistant message events. pi-durable runs the tools; Swift only reports the calls.
import {
	type Api,
	type AssistantMessage,
	type Context,
	createProvider,
	type Model,
	type ProviderStreams,
	type SimpleStreamOptions,
	type TextContent,
	type ThinkingContent,
	type ToolCall,
	type Usage,
} from "@earendil-works/pi-ai";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai/utils/event-stream";
import { getCurrentSystemPrompt, getCurrentTools } from "@earendil-works/pi-ai/utils/transcript";
import type { AssistantMessageEventStream } from "@earendil-works/pi-ai/utils/event-stream";
import { type Args, hostStream, register } from "./core.ts";
import { modelsState } from "./models.ts";

const ZERO_USAGE: Usage = {
	input: 0,
	output: 0,
	cacheRead: 0,
	cacheWrite: 0,
	totalTokens: 0,
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};

type JsonSchema = Record<string, unknown>;

/**
 * A JSON schema whose object properties keep their order as `x-order`, which Swift's dictionaries would lose. Swift
 * normalizes the rest for Foundation Models' `GenerationSchema`.
 */
export function foundationSchema(schema: unknown): unknown {
	if (Array.isArray(schema)) return schema.map((item) => foundationSchema(item));
	if (schema === null || typeof schema !== "object") return schema;
	const result: JsonSchema = {};
	for (const [key, value] of Object.entries(schema as JsonSchema)) {
		if (key === "$schema") continue;
		result[key] =
			key === "properties" && value !== null && typeof value === "object"
				? Object.fromEntries(Object.entries(value as JsonSchema).map(([name, property]) => [name, foundationSchema(property)]))
				: foundationSchema(value);
	}
	if (result.properties !== undefined && result["x-order"] === undefined) result["x-order"] = Object.keys(result.properties as JsonSchema);
	return result;
}

/** What Swift answers for one request. */
type Answer = {
	toolCalls: { id: string; name: string; arguments: ToolCall["arguments"] }[];
	stopReason: AssistantMessage["stopReason"];
	usage: { input: number; cachedInput: number; output: number; reasoning: number };
	errorMessage?: string;
};

function respond(models: number, provider: string, model: Model<Api>, context: Context, options: SimpleStreamOptions | undefined) {
	const stream = createAssistantMessageEventStream();
	void run(stream, models, provider, model, context, options);
	return stream;
}

async function run(
	stream: AssistantMessageEventStream,
	models: number,
	provider: string,
	model: Model<Api>,
	context: Context,
	options: SimpleStreamOptions | undefined,
): Promise<void> {
	const signal = options?.signal;
	const base = { role: "assistant" as const, api: model.api, provider: model.provider, model: model.id, timestamp: Date.now() };
	const content: (TextContent | ThinkingContent | ToolCall)[] = [];
	const partial = (): AssistantMessage => ({ ...base, content: content.map((block) => ({ ...block })), usage: ZERO_USAGE, stopReason: "stop" });
	let text = -1;
	let thinking = -1;
	const close = () => {
		if (thinking >= 0) {
			stream.push({ type: "thinking_end", contentIndex: thinking, content: (content[thinking] as ThinkingContent).thinking, partial: partial() });
			thinking = -1;
		}
		if (text >= 0) {
			stream.push({ type: "text_end", contentIndex: text, content: (content[text] as TextContent).text, partial: partial() });
			text = -1;
		}
	};
	stream.push({ type: "start", partial: partial() });
	try {
		const messages = context.messages;
		const answer = await hostStream<Answer>(
			"foundationModels.respond",
			{
				models,
				provider,
				model: model.id,
				instructions: getCurrentSystemPrompt(messages as never) || (context as { systemPrompt?: string }).systemPrompt || "",
				tools: getCurrentTools(messages as never).map((tool) => ({
					name: tool.name,
					description: tool.description,
					parameters: foundationSchema(tool.parameters),
				})),
				messages: messages.filter((message) => message.role !== "system"),
				options: {
					temperature: options?.temperature ?? null,
					maxTokens: options?.maxTokens ?? null,
					reasoning: options?.reasoning ?? null,
					toolChoice: options?.toolChoice ?? null,
				},
			},
			(event: Args) => {
				if (event.type === "text") {
					if (thinking >= 0) close();
					if (text < 0) {
						content.push({ type: "text", text: "" });
						text = content.length - 1;
						stream.push({ type: "text_start", contentIndex: text, partial: partial() });
					}
					(content[text] as TextContent).text += event.delta;
					stream.push({ type: "text_delta", contentIndex: text, delta: event.delta, partial: partial() });
				} else if (event.type === "thinking") {
					if (thinking < 0) {
						content.push({ type: "thinking", thinking: "" });
						thinking = content.length - 1;
						stream.push({ type: "thinking_start", contentIndex: thinking, partial: partial() });
					}
					(content[thinking] as ThinkingContent).thinking += event.delta;
					stream.push({ type: "thinking_delta", contentIndex: thinking, delta: event.delta, partial: partial() });
				}
			},
			signal === undefined ? undefined : { abortSignal: signal },
		);
		close();
		for (const call of answer.toolCalls) {
			const block: ToolCall = { type: "toolCall", id: call.id, name: call.name, arguments: call.arguments };
			content.push({ ...block, arguments: {} });
			const index = content.length - 1;
			stream.push({ type: "toolcall_start", contentIndex: index, partial: partial() });
			stream.push({ type: "toolcall_delta", contentIndex: index, delta: JSON.stringify(call.arguments), partial: partial() });
			content[index] = block;
			stream.push({ type: "toolcall_end", contentIndex: index, toolCall: block, partial: partial() });
		}
		const input = Math.max(0, answer.usage.input - answer.usage.cachedInput);
		const usage: Usage = {
			...ZERO_USAGE,
			input,
			cacheRead: answer.usage.cachedInput,
			output: answer.usage.output,
			...(answer.usage.reasoning > 0 ? { reasoning: answer.usage.reasoning } : {}),
			totalTokens: answer.usage.input + answer.usage.output,
		};
		const message: AssistantMessage = {
			...partial(),
			usage,
			stopReason: answer.stopReason,
			...(answer.errorMessage === undefined ? {} : { errorMessage: answer.errorMessage }),
		};
		if (message.stopReason === "error") {
			stream.push({ type: "error", reason: "error", error: message });
		} else {
			stream.push({ type: "done", reason: message.stopReason as "stop" | "length" | "toolUse", message });
		}
		stream.end(message);
	} catch (error) {
		close();
		const aborted = signal?.aborted === true;
		const message: AssistantMessage = {
			...partial(),
			stopReason: aborted ? "aborted" : "error",
			errorMessage: aborted ? "Request was aborted" : error instanceof Error ? error.message : String(error),
		};
		stream.push({ type: "error", reason: aborted ? "aborted" : "error", error: message });
		stream.end(message);
	}
}

register({
	/** A provider whose models are `LanguageModel`s Swift registered for this models collection. */
	"models.addFoundationModels": (args) => {
		const state = modelsState(args.id);
		const api = `foundation-models:${args.provider}`;
		const streams: ProviderStreams = {
			stream: (model, context, options) => respond(args.id, args.provider, model, context as Context, options as SimpleStreamOptions),
			streamSimple: (model, context, options) => respond(args.id, args.provider, model, context as Context, options),
		};
		state.models.setProvider(
			createProvider({
				id: args.provider,
				name: args.name ?? args.provider,
				baseUrl: "apple://foundation-models",
				// On-device and Private Cloud Compute models need no credentials.
				auth: { apiKey: { name: args.name ?? args.provider, resolve: async () => ({ auth: { apiKey: "unused" } }) } },
				models: (args.models as Args[]).map((model) => ({
					id: model.id,
					name: model.name ?? model.id,
					api,
					provider: args.provider,
					baseUrl: "apple://foundation-models",
					reasoning: model.reasoning === true,
					input: model.input ?? ["text"],
					cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
					contextWindow: model.contextWindow,
					maxTokens: model.maxTokens,
				})),
				api: { [api]: streams },
			}) as never,
		);
	},
});
