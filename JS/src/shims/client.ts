// How the app identifies itself to model providers, wherever pi-ai would say "pi" (`Runtime.Client` in Swift).
//
// Replaces pi-ai's `utils/pi-user-agent.js` (same export, so its provider APIs send the app's `User-Agent`), and
// build.mjs patches pi-ai's other "pi"s (the sign-in name, OpenAI Codex's originator, xAI's referrer) to `clientName()`.
import { native } from "../runtime/native.ts";

interface Client {
	name: string;
	userAgent: string;
}

let client: Client | undefined;

function current(): Client {
	// Outside the Swift host (the Node tests), a name of its own.
	client ??= typeof native?.client === "function" ? (JSON.parse(native.client()) as Client) : { name: "PiDurableKit", userAgent: "PiDurableKit" };
	return client;
}

/** The app's name, such as "Pelican". */
export function clientName(): string {
	return current().name;
}

/** The app's `User-Agent`, such as `Pelican/1.2 (iOS 27.0)`. Named as pi-ai's is, which this module stands in for. */
export function getPiUserAgent(): string {
	return current().userAgent;
}
