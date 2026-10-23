// The shipped bundle carries build.mjs's OAuth error patches (Quorum M0-90b): none of the texts that quoted a response,
// its URL or a stack is left, and the shim that replaced them is in. A tripwire for a build that skipped them.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const bundle = readFileSync(new URL("../../Sources/PiDurableKit/Resources/pi-durable.js", import.meta.url), "utf8");
const count = (text: string) => bundle.split(text).length - 1;

test("the bundle quotes no OAuth response, URL or stack in its errors", () => {
	const quoting = [
		"url=${",
		"body=${",
		"stack=${",
		"missing fields: ${JSON.stringify",
		"response: ${JSON.stringify",
		"text.slice(0,300)",
		// GitHub Copilot's; pi-messages' model-request formatter keeps its own (a provider's text, M0-90d).
		"statusText}: ${await",
		"Complete setup at ${",
		"authorization failed: ${",
	];
	for (const text of quoting) {
		assert.equal(count(text), 0, text);
	}
	assert.ok(count("causeTag") > 0, "the cause shim is bundled");
});
