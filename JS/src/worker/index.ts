// The code mode worker: a JavaScriptCore context of its own, on its own thread, that runs code mode's QuickJS VMs so a
// script that computes doesn't hold up the runtime's JavaScript thread. It is the remote side of pi-codemode's
// `RemoteCodemodeSandbox`: the runtime keeps the tools, the deadline and the abort, and every exchange of messages
// crosses through Swift (`CodemodeWorkers`).
//
// Only the web globals QuickJS's host code uses: timers, console, crypto, performance, text encoding, WebAssembly.
import "../runtime/native.ts";
import "../runtime/globals.ts";
import "../runtime/encoding.ts";
import "../runtime/wasm.ts";
import {
	type CodemodeRemoteReply,
	type CodemodeRemoteRequest,
	DEFAULT_INTERRUPT_BUDGET,
	serveCodemodeRemote,
} from "@earendil-works/pi-codemode/portable";

/** What the worker's Swift side provides besides the runtime's natives. */
interface WorkerNative {
	fsReadFile(path: string): Uint8Array;
	/** Sends one exchange's messages to the runtime; Swift answers with `__worker.reply(id, replyJSON)`. */
	exchange(id: number, messagesJSON: string): void;
	/** The execution ended. */
	done(): void;
}

const native = (globalThis as unknown as { __native: WorkerNative }).__native;

/** QuickJS, compiled once per worker. */
const modules = new Map<string, Promise<object>>();
function quickJS(path: string): Promise<object> {
	let compiled = modules.get(path);
	if (compiled === undefined) {
		compiled = WebAssembly.compile(native.fsReadFile(path) as BufferSource);
		modules.set(path, compiled);
		compiled.catch(() => modules.delete(path));
	}
	return compiled;
}

let nextExchange = 1;
const waiting = new Map<number, (reply: CodemodeRemoteReply) => void>();

(globalThis as Record<string, unknown>).__worker = {
	/** Runs one execution; calls `done()` once it has ended. */
	serve(requestJSON: string, wasmPath: string): void {
		const request = JSON.parse(requestJSON) as CodemodeRemoteRequest;
		const exchange = (messages: unknown[]) =>
			new Promise<CodemodeRemoteReply>((resolve) => {
				const id = nextExchange++;
				waiting.set(id, resolve);
				native.exchange(id, JSON.stringify(messages));
			});
		// The runtime chose the budget; nothing here needs a lower one.
		const maxInterruptBudget = request.interruptBudget ?? DEFAULT_INTERRUPT_BUDGET;
		void serveCodemodeRemote(request, exchange, { wasm: quickJS(wasmPath) as never, maxInterruptBudget }).finally(() => {
			// Exchanges still waiting (the client stopped) end with the execution.
			for (const resolve of waiting.values()) resolve({ type: "stop" });
			waiting.clear();
			native.done();
		});
	},

	/** The runtime's answer to an exchange. */
	reply(id: number, replyJSON: string): void {
		const resolve = waiting.get(id);
		if (resolve === undefined) return;
		waiting.delete(id);
		resolve(JSON.parse(replyJSON) as CodemodeRemoteReply);
	},
};
