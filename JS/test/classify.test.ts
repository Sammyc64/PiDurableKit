// Classifier providers: a custom provider's `type: "classifier"` models answer `models.classify` through pi-ai's own
// classifier API (TypeSafe System One), served here by a local stub.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { after, beforeEach, test } from "node:test";

// The Swift host as the bridge sees it: no stored credentials. Installed before the bridge modules load.
type Callbacks = { hostResolve(id: number, json: string): void };
const replies: Record<string, unknown> = { "credentials.read": null, "credentials.list": [], "credentials.write": null };
(globalThis as Record<string, unknown>).__native = {
	hostCall(id: number, method: string) {
		const callbacks = (globalThis as Record<string, unknown>).__runtime as Callbacks;
		setTimeout(() => callbacks.hostResolve(id, JSON.stringify(replies[method] ?? null)));
	},
	hostCancel() {},
};
const { methods } = await import("../src/bridge/core.ts");
await import("../src/bridge/models.ts");

type Json = Record<string, unknown>;
const context = () => ({ abortSignal: new AbortController().signal }) as never;
/** A bridge call as Swift makes it: a method that throws rejects. */
const call = async (method: string, args: Json) => methods[method]!(args, context());

// MARK: A System One server

interface Received {
	method: string | undefined;
	url: string | undefined;
	authorization: string | undefined;
	body: Json;
}

let received: Received[] = [];
let respond: (body: Json) => { status: number; body: unknown };

/** Answers every question of a request; `bool` questions arrive as System One's `noul`. */
function answerAll(body: Json) {
	const answers: Json = {};
	for (const [id, question] of Object.entries(body.questions as Record<string, Json>)) {
		if (question.type === "noul") answers[id] = { type: "noul", noul: 0.9 };
		if (question.type === "choice") answers[id] = { type: "choice", choice: "billing", probabilities: { billing: 0.7, support: 0.3 }, confidence: 0.8 };
		if (question.type === "score") answers[id] = { type: "score", score: 2, confidence: 0.6 };
	}
	return { status: 200, body: { answers, usage: { input_tokens: 12, output_tokens: 3 } } };
}

const server = createServer(async (request, response) => {
	let text = "";
	for await (const chunk of request) text += chunk;
	const body = JSON.parse(text) as Json;
	received.push({ method: request.method, url: request.url, authorization: request.headers.authorization, body });
	const reply = respond(body);
	response.writeHead(reply.status, { "content-type": "application/json" });
	response.end(JSON.stringify(reply.body));
});
await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
const baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1`;
after(() => server.close());

let nextModels = 1;
let models = 0;
beforeEach(async () => {
	received = [];
	respond = answerAll;
	models = nextModels++;
	await call("models.create", { id: models, builtin: false });
});

/** A keyless local classifier service, with a chat model beside its classifier. */
function registerClef(api = "typesafe-system-one") {
	return call("models.addProvider", {
		id: models,
		provider: {
			id: "clef",
			baseUrl,
			api: "openai-completions",
			models: [
				{ id: "clef-1", type: "classifier", api },
				{ id: "chat-1" },
			],
		},
	});
}

const questions = {
	spam: { type: "bool", instructions: "Is this message spam?", criteria: { true: "Unsolicited bulk mail", false: "Anything else" } },
	topic: { type: "choice", instructions: "What is it about?", criteria: { billing: "Payments and invoices", support: "Help with the product" } },
	urgency: { type: "score", instructions: "How urgent is it?", criteria: ["Whenever", "This week", "Today"] },
};

// MARK: Tests

test("a classifier model is listed by its type; chat listings stay chat only", async () => {
	await registerClef();
	const chat = (await call("models.list", { id: models, provider: "clef" })) as Json[];
	assert.deepEqual(
		chat.map((model) => [model.id, model.type]),
		[["chat-1", "chat"]],
	);
	const classifiers = (await call("models.list", { id: models, provider: "clef", type: "classifier" })) as Json[];
	assert.deepEqual(
		classifiers.map((model) => [model.id, model.type, model.api]),
		[["clef-1", "classifier", "typesafe-system-one"]],
	);
	// Chat defaults don't apply to a classifier.
	assert.deepEqual([chat[0]!.maxTokens, classifiers[0]!.maxTokens], [16384, undefined]);
});

test("models.classify answers bool, choice and score questions through System One", async () => {
	await registerClef();
	const result = (await call("models.classify", {
		id: models,
		model: { provider: "clef", modelId: "clef-1" },
		context: { state: { text: "Your invoice is overdue" }, questions },
	})) as Json;
	assert.equal(result.stopReason, "stop", String(result.errorMessage));
	assert.deepEqual(result.answers, {
		spam: { type: "bool", probability: 0.9 },
		topic: { type: "choice", choice: "billing", probabilities: { billing: 0.7, support: 0.3 }, confidence: 0.8 },
		urgency: { type: "score", score: 2, confidence: 0.6 },
	});
	assert.deepEqual([(result.usage as Json).input, (result.usage as Json).output], [12, 3]);

	assert.equal(received.length, 1);
	const [request] = received;
	assert.equal(request!.method, "POST");
	assert.equal(request!.url, "/v1/systemone");
	// A keyless service gets the placeholder key the chat APIs get: System One refuses to send without one.
	assert.equal(request!.authorization, "Bearer unused");
	assert.deepEqual(request!.body, {
		model: "clef-1",
		state: { text: "Your invoice is overdue" },
		questions: { ...questions, spam: { ...questions.spam, type: "noul" } },
	});
});

test("an error response comes back as an error result, not an empty answer", async () => {
	await registerClef();
	respond = () => ({ status: 400, body: { error: "questions must not be empty" } });
	const result = (await call("models.classify", {
		id: models,
		model: { provider: "clef", modelId: "clef-1" },
		context: { state: {}, questions },
	})) as Json;
	assert.equal(result.stopReason, "error");
	assert.match(String(result.errorMessage), /400/);
	assert.deepEqual(result.answers, {});
});

test("an unknown classifier API is refused at registration", async () => {
	await assert.rejects(registerClef("made-up-classifier"), /Unsupported classifier API "made-up-classifier"/);
});

test("models.classify only takes classifier models", async () => {
	await registerClef();
	await assert.rejects(
		call("models.classify", { id: models, model: { provider: "clef", modelId: "chat-1" }, context: { state: {}, questions } }),
		(error: Error) => error.name === "NotFound" && /clef\/chat-1/.test(error.message),
	);
});

/** Models with the built-in providers, and a keyless gateway at the stub serving `catalog`'s models. */
async function followCatalog(catalog: string) {
	const id = nextModels++;
	await call("models.create", { id, builtin: true });
	await call("models.addProvider", { id, provider: { id: "gateway", baseUrl, api: "openai-completions", catalog, models: [] } });
	return id;
}

test("a provider following a built-in catalog classifies with the catalog's System One classifiers", async () => {
	const id = await followCatalog("openrouter");
	const classifiers = (await call("models.list", { id, provider: "gateway", type: "classifier" })) as Json[];
	assert.ok(classifiers.length > 0);
	assert.ok(classifiers.every((model) => model.api === "typesafe-system-one" && model.provider === "gateway" && model.baseUrl === baseUrl));
	const result = (await call("models.classify", {
		id,
		model: { provider: "gateway", modelId: classifiers[0]!.id },
		context: { state: {}, questions },
	})) as Json;
	assert.equal(result.stopReason, "stop", String(result.errorMessage));
	assert.deepEqual(
		received.map((request) => [request.url, request.body.model]),
		[["/v1/systemone", classifiers[0]!.id]],
	);
});

test("a followed catalog leaves out the classifiers it has no classifier API for", async () => {
	// OpenAI's classifiers use its Decisions API.
	const id = await followCatalog("openai");
	assert.ok(((await call("models.list", { id, provider: "openai", type: "classifier" })) as Json[]).length > 0, "the catalog has classifiers to leave out");
	assert.ok(((await call("models.list", { id, provider: "gateway" })) as Json[]).length > 0);
	assert.deepEqual(await call("models.list", { id, provider: "gateway", type: "classifier" }), []);
});
