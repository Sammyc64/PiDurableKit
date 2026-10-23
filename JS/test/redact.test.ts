// What pi-ai's OAuth errors may say about a provider's response (Quorum M0-90b): the shim build.mjs patches them to use,
// and the bridge's error serialization. None of it may quote the response, which can hold a token.
import assert from "node:assert/strict";
import { test } from "node:test";
import { causeTag, invalidFields, oauthErrorCode, oauthErrorSuffix } from "../src/shims/redact.ts";

(globalThis as Record<string, unknown>).__native = { hostCall() {}, hostCancel() {} };
const { serializeError } = await import("../src/bridge/core.ts");
const { ModelsError } = await import("../node_modules/@earendil-works/pi-ai/dist/utils/models-error.js");

const secret = `SECRET-${crypto.randomUUID()}`;

test("causeTag names the status, an OAuth code, a transport failure and an invalid response, and nothing else", () => {
	const status = Object.assign(new Error(`refused: ${secret}`), { status: 503 });
	const cases: [unknown, string][] = [
		[new Error("Kimi Code token refresh unauthorized (status 401): invalid_grant"), "HTTP error (401), invalid_grant"],
		[new Error("HTTP request failed. status=400; body=x"), "HTTP error (400)"],
		[new Error("xAI OAuth token refresh failed (HTTP 400): invalid_grant"), "HTTP error (400), invalid_grant"],
		[new Error("OpenAI Codex token refresh failed (429)"), "HTTP error (429)"],
		[status, "HTTP error (503)"],
		[new TypeError("fetch failed: The network connection was lost."), "fetch failed"],
		[Object.assign(new Error("The operation timed out."), { name: "TimeoutError" }), "timed out"],
		[new Error("Kimi Code token refresh response missing fields: refresh_token"), "invalid token response"],
		[new Error("Anthropic token refresh returned invalid JSON (12 bytes)"), "invalid token response"],
		// The fetch shim's own parse error, for a token response that isn't JSON.
		[new SyntaxError("The response isn't valid JSON"), "invalid token response"],
		// A byte count in parentheses isn't a status, so a 2xx that isn't JSON doesn't read as retryable.
		[new Error("Anthropic token refresh returned invalid JSON (503 bytes)"), "invalid token response"],
		[new Error(`unclassified ${secret}`), ""],
		["a string cause", ""],
		[null, ""],
		[Object.create(null), ""],
	];
	for (const [index, [cause, expected]] of cases.entries()) assert.equal(causeTag(cause), expected, `case ${index}`);
	// A JavaScriptCore stack's column numbers aren't a status.
	assert.equal(causeTag(new Error("failed at pi-durable.js:1:500200")), "");
});

test("causeTag never quotes its cause, wherever a secret sits in it", () => {
	// A deterministic generator, so a failure repeats.
	let seed = 0x90b;
	const next = (bound: number) => {
		seed = (seed * 1103515245 + 12345) % 2 ** 31;
		return seed % bound;
	};
	const templates = [
		"HTTP request failed. status=400; url=https://example.test/token; body=",
		"Kimi Code token refresh unauthorized (status 401): ",
		"OpenAI Codex token refresh failed (429): ",
		"fetch failed: ",
		"Token exchange returned invalid JSON. body=",
		'{"error":"invalid_grant","error_description":"',
	];
	for (let index = 0; index < 50; index += 1) {
		const template = templates[next(templates.length)]!;
		const at = next(template.length + 1);
		const message = template.slice(0, at) + secret + template.slice(at);
		const cause = next(2) === 0 ? new Error(message) : message;
		assert.ok(!causeTag(cause).includes(secret), message);
		assert.ok(!causeTag(cause).includes("SECRET"), message);
	}
});

test("only OAuth's own error codes pass, so none carries a provider's text", () => {
	for (const code of ["invalid_grant", "authorization_pending", "slow_down", "access_denied", "expired_token"]) {
		assert.equal(oauthErrorCode(code), code);
		assert.equal(oauthErrorSuffix(code), `: ${code}`);
	}
	for (const value of [secret, "invalid_grant: and more", "Invalid_Grant", "", 400, undefined, null, { error: "invalid_grant" }]) {
		assert.equal(oauthErrorCode(value), undefined, String(value));
		assert.equal(oauthErrorSuffix(value), "");
	}
});

test("invalidFields names the fields that fail their check, never their values", () => {
	const json = { access_token: secret, expires_in: "3600" };
	const named = invalidFields(json, { access_token: Boolean, refresh_token: Boolean, expires_in: (value) => typeof value === "number" });
	assert.equal(named, "refresh_token, expires_in");
	assert.equal(invalidFields(secret, { access_token: Boolean }), "not a JSON object");
	assert.equal(invalidFields({ access_token: secret }, { access_token: Boolean }), "none");
});

test("the bridge passes a cause to Swift only for SessionFailed, the one Swift reads", () => {
	const failed = new ModelsError("oauth", "OAuth refresh failed for anthropic", { cause: new Error(`body=${secret}`) });
	assert.equal(serializeError(failed).cause, null);
	assert.equal(serializeError(failed).stack, null, "no stack, which holds the bundle's path");
	const session = Object.assign(new Error("The session failed", { cause: new Error("disk full") }), { name: "SessionFailed" });
	assert.deepEqual((serializeError(session).cause as { message: string }).message, "disk full");
});
