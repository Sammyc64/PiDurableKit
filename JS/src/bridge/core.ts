// Bridge plumbing shared by every module: Swift → JavaScript calls, JavaScript → Swift host calls, pushed streams,
// and scoped handles that let Swift reach JavaScript objects (transactions, tool calls, task runs) by number.
import { BACKGROUND_CONTEXT, withAbortSignal } from "@earendil-works/chord/context";
import type { Context } from "@earendil-works/chord";
import { native, runtimeCallbacks } from "../runtime/native.ts";

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
// biome-ignore lint/suspicious/noExplicitAny: arguments arrive as untyped JSON from Swift
export type Args = Record<string, any>;

// MARK: Methods (Swift → JavaScript)

/** Bridge methods by name. Modules register theirs with `register()`. */
export const methods: Record<string, (args: Args, context: Context) => unknown> = {};

export function register(entries: Record<string, (args: Args, context: Context) => unknown>): void {
	for (const [name, handler] of Object.entries(entries)) {
		if (name in methods) throw new Error(`Bridge method ${name} registered twice`);
		methods[name] = handler;
	}
}

export function serializeError(error: unknown): Json {
	if (error instanceof Error) {
		return {
			name: error.name,
			message: error.message,
			stack: error.stack ?? null,
			code: ((error as { code?: unknown }).code as Json) ?? null,
			// The fields pi-durable's error classes carry: `ConversationBusy`, `FileError`, `ExecutionError`.
			conversationId: ((error as { conversationId?: unknown }).conversationId as Json) ?? null,
			path: ((error as { path?: unknown }).path as Json) ?? null,
			spillPath: ((error as { spillPath?: unknown }).spillPath as Json) ?? null,
			// `SessionFailed` carries the storage error that failed the Session.
			cause: error.cause === undefined ? null : serializeError(error.cause),
		};
	}
	return { name: "Error", message: messageOf(error), stack: null, code: null };
}

/** `String(value)`, without throwing for values such as `Object.create(null)`. */
function messageOf(value: unknown): string {
	try {
		return String(value);
	} catch {
		return "Unknown error";
	}
}

const calls = new Map<number, AbortController>();

(globalThis as Record<string, unknown>).__bridge = {
	call(id: number, method: string, argsJSON: string): void {
		const controller = new AbortController();
		calls.set(id, controller);
		const context = withAbortSignal(controller.signal, BACKGROUND_CONTEXT);
		Promise.resolve()
			.then(() => {
				const handler = methods[method];
				if (handler === undefined) throw new Error(`Unknown bridge method ${method}`);
				return handler(JSON.parse(argsJSON) as Args, context);
			})
			.then(
				(result) => {
					calls.delete(id);
					native.reply(id, JSON.stringify(result ?? null), null);
				},
				(error) => {
					calls.delete(id);
					native.reply(id, null, JSON.stringify(serializeError(error)));
				},
			);
	},
	cancel(id: number): void {
		calls.get(id)?.abort();
	},
};

// MARK: Host calls (JavaScript → Swift)

let nextHostCall = 1;
const hostCalls = new Map<number, { resolve(value: unknown): void; reject(error: unknown): void }>();

runtimeCallbacks.hostResolve = ((id: number, json: string) => {
	const call = hostCalls.get(id);
	if (call === undefined) return;
	hostCalls.delete(id);
	call.resolve(json === "" ? undefined : JSON.parse(json));
}) as never;

runtimeCallbacks.hostReject = ((id: number, json: string) => {
	const call = hostCalls.get(id);
	if (call === undefined) return;
	hostCalls.delete(id);
	call.reject(hostError(json));
}) as never;

function hostError(json: string): Error {
	const info = JSON.parse(json) as { name?: string; message?: string; code?: string; path?: string };
	const error = new Error(info.message ?? "Host call failed");
	if (info.name) error.name = info.name;
	// Environments implemented in Swift report file and command failures with pi-durable's codes.
	if (info.code) Object.assign(error, { code: info.code });
	if (info.path) Object.assign(error, { path: info.path });
	return error;
}

/** Calls Swift and awaits its answer. Aborting `context` cancels the Swift task. */
export function host<T>(method: string, args: Args, context?: Pick<Context, "abortSignal">): Promise<T> {
	const id = nextHostCall++;
	const signal = context?.abortSignal;
	return new Promise<T>((resolve, reject) => {
		if (signal?.aborted) {
			reject(signal.reason);
			return;
		}
		const onAbort = () => native.hostCancel(id);
		signal?.addEventListener("abort", onAbort, { once: true });
		hostCalls.set(id, {
			resolve: (value) => {
				signal?.removeEventListener("abort", onAbort);
				resolve(value as T);
			},
			reject: (error) => {
				signal?.removeEventListener("abort", onAbort);
				reject(error);
			},
		});
		native.hostCall(id, method, JSON.stringify(args));
	});
}

/** Events Swift pushes during a host call, by the call's stream number (`host.event`). */
const hostStreams = new Map<number, (event: Args) => void>();
let nextHostStream = 1;

/**
 * Calls Swift and awaits its answer, receiving the events Swift pushes meanwhile with `HostRouter.events(_:)`; every
 * event arrives before the answer.
 */
export async function hostStream<T>(
	method: string,
	args: Args,
	onEvent: (event: Args) => void,
	context?: Pick<Context, "abortSignal">,
): Promise<T> {
	const stream = nextHostStream++;
	hostStreams.set(stream, onEvent);
	try {
		return await host<T>(method, { ...args, hostStream: stream }, context);
	} finally {
		hostStreams.delete(stream);
	}
}

/**
 * Calls synchronous Swift code (migrations, task initial states, argument repair, the clock) and returns its answer.
 * The Swift side must not wait for anything.
 */
export function hostSync<T>(method: string, args: Args): T {
	const result = JSON.parse(native.hostCallSync(method, JSON.stringify(args))) as { value?: T; error?: string };
	if (result.error !== undefined) throw hostError(result.error);
	return result.value as T;
}

/** A context whose abort signal is `signal`, or the background context. */
export function contextOf(signal: AbortSignal | undefined): Context {
	return signal === undefined ? BACKGROUND_CONTEXT : withAbortSignal(signal, BACKGROUND_CONTEXT);
}

// MARK: Streams (JavaScript → Swift, push)

const streams = new Map<number, () => Promise<unknown> | void>();

export function openStream(stream: number, stop: () => Promise<unknown> | void): void {
	streams.set(stream, stop);
}

export function emit(stream: number, value: unknown): void {
	native.emit(stream, JSON.stringify(value));
}

export function finish(stream: number, error?: unknown): void {
	if (!streams.delete(stream)) return;
	native.finish(stream, error === undefined ? null : JSON.stringify(serializeError(error)));
}

register({
	"host.event": (args) => {
		hostStreams.get(args.hostStream)?.(args.event);
	},
	"stream.stop": async (args) => {
		const stop = streams.get(args.stream);
		if (stop === undefined) return;
		await stop();
		finish(args.stream);
	},
});

// MARK: Scoped handles

let nextHandle = 1;
const handles = new Map<number, unknown>();

/** Makes `value` reachable from Swift by number until `close`. */
export function openHandle(value: unknown): number {
	const id = nextHandle++;
	handles.set(id, value);
	return id;
}

export function closeHandle(id: number): void {
	handles.delete(id);
}

/** Runs `body` with `value` reachable from Swift. */
export async function withHandle<T>(value: unknown, body: (handle: number) => Promise<T>): Promise<T> {
	const id = openHandle(value);
	try {
		return await body(id);
	} finally {
		closeHandle(id);
	}
}

export function handle<T>(id: number): T {
	if (!handles.has(id)) {
		throw Object.assign(new Error("This handle is no longer valid: its call, commit, or task phase has ended"), {
			name: "HandleExpired",
		});
	}
	return handles.get(id) as T;
}

/** JSON without `undefined` fields; `null` for `undefined`. */
export function plain<T>(value: T): Json {
	return value === undefined ? null : (JSON.parse(JSON.stringify(value)) as Json);
}

/** The error a stream ends with for a watch's terminal result: a listener's error, or the one that failed the Session. */
export function watchEndError(end: { reason: string; error?: unknown }): unknown {
	if (end.reason === "listener_error") return end.error;
	if (end.reason === "session_failed") {
		const cause = end.error;
		return Object.assign(new Error(`The session failed: ${cause instanceof Error ? cause.message : messageOf(cause)}`, { cause }), {
			name: "SessionFailed",
		});
	}
	return undefined;
}
