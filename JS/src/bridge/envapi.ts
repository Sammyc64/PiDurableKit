// Execution environments as Swift sees them (`ExecutionEnv` in Swift): the environment of a tool call, task phase, or
// section, or one the host builds for a conversation, reached through handles.
import type { Context } from "@earendil-works/chord";
import type { ConversationId } from "@earendil-works/pi-durable";
import type { BinaryReader, DirReader, ExecutionEnv, ListFilesOptions, Result, TextLineReader } from "@earendil-works/pi-durable/env";
import { type Args, closeHandle, contextOf, emit, finish, handle, openHandle, openStream, register } from "./core.ts";
import { fromBase64, toBase64 } from "./env.ts";
import type { Scope } from "./scopes.ts";
import { conversation, harnessState } from "./state.ts";

/** An environment reachable from Swift; `owner` is the handle list of the scope it belongs to, if any. */
type EnvRef = { readonly env: ExecutionEnv; readonly owner?: number[] };

/** Opens a handle for `env`, closed with `owner`'s scope when given. */
export function openEnv(env: ExecutionEnv, owner?: number[]) {
	const id = openHandle({ env, owner } satisfies EnvRef);
	owner?.push(id);
	return { handle: id, id: env.id, cwd: env.cwd };
}

function envOf(args: Args): ExecutionEnv {
	return handle<EnvRef>(args.env).env;
}

/** A child object (reader) of an environment handle, closed with the same scope. */
function openChild(args: Args, value: unknown): number {
	const id = openHandle(value);
	handle<EnvRef>(args.env).owner?.push(id);
	return id;
}

/** The value of a pi-durable `Result`, or its error thrown. */
async function unwrap<T>(result: Promise<Result<T, Error>>): Promise<T> {
	const settled = await result;
	if (!settled.ok) throw settled.error;
	return settled.value;
}

function content(args: Args): string | Uint8Array {
	return typeof args.base64 === "string" ? fromBase64(args.base64) : (args.text as string);
}

register({
	/** The environment of the running tool call, task phase, or section; `null` without one. */
	"scope.env": async (args, context) => {
		const scope = handle<Scope>(args.handle);
		const env = scope.tool !== undefined ? scope.tool.env : scope.runtime !== undefined ? await scope.runtime.env(context) : scope.env;
		return env === undefined ? null : openEnv(env, scope.children);
	},
	/** Builds a conversation's environment as the harness would for a tool call, for the host to use. */
	"harness.env": async (args, context) => {
		const state = harnessState(args.harness);
		if (state.env === undefined) return null;
		const found = await conversation(args, context);
		const agent = await found.agent(context);
		const env = await state.env(
			{ conversationId: args.conversation as ConversationId, ...(agent.cwd === undefined ? {} : { cwd: agent.cwd }), read: state.harness },
			context,
		);
		return env === undefined ? null : openEnv(env);
	},
	"env.release": async (args) => {
		closeHandle(args.env);
	},
	"env.cleanup": (args, context) => envOf(args).cleanup(context),
	"env.setCwd": (args) => {
		envOf(args).cwd = args.cwd;
	},

	"env.absolutePath": (args, context) => unwrap(envOf(args).absolutePath(args.path, context)),
	"env.joinPath": (args, context) => unwrap(envOf(args).joinPath(args.parts, context)),
	"env.canonicalPath": (args, context) => unwrap(envOf(args).canonicalPath(args.path, context)),
	"env.exists": (args, context) => unwrap(envOf(args).exists(args.path, context)),
	"env.fileInfo": (args, context) => unwrap(envOf(args).fileInfo(args.path, context)),
	"env.listDir": (args, context) => unwrap(envOf(args).listDir(args.path, context)),
	"env.listFiles": async (args, context) => {
		const env = envOf(args);
		if (env.listFiles === undefined) {
			throw Object.assign(new Error("This environment cannot list files"), { name: "FileError", code: "not_supported", path: args.path });
		}
		return unwrap(env.listFiles(args.path, (args.options ?? undefined) as ListFilesOptions | undefined, context));
	},
	"env.readText": (args, context) => unwrap(envOf(args).readTextFile(args.path, context)),
	"env.readTextLines": (args, context) =>
		unwrap(envOf(args).readTextLines(args.path, args.maxLines == null ? undefined : { maxLines: args.maxLines }, context)),
	"env.readBinary": async (args, context) => toBase64(await unwrap(envOf(args).readBinaryFile(args.path, context))),
	"env.write": (args, context) => unwrap(envOf(args).writeFile(args.path, content(args), context)),
	"env.append": (args, context) => unwrap(envOf(args).appendFile(args.path, content(args), context)),
	"env.truncate": (args, context) => unwrap(envOf(args).truncateFile(args.path, args.size, context)),
	"env.flush": (args, context) => unwrap(envOf(args).flushFile(args.path, context)),
	"env.rename": (args, context) => unwrap(envOf(args).renameFile(args.path, args.destination, context)),
	"env.createDir": (args, context) => unwrap(envOf(args).createDir(args.path, { recursive: args.recursive === true }, context)),
	"env.remove": (args, context) =>
		unwrap(envOf(args).remove(args.path, { recursive: args.recursive === true, force: args.force === true }, context)),
	"env.createTempDir": (args, context) => unwrap(envOf(args).createTempDir(args.prefix ?? undefined, context)),
	"env.createTempFile": (args, context) =>
		unwrap(
			envOf(args).createTempFile(
				{ ...(args.prefix == null ? {} : { prefix: args.prefix }), ...(args.suffix == null ? {} : { suffix: args.suffix }) },
				context,
			),
		),

	// Readers

	"env.openBinaryReader": async (args, context) =>
		openChild(args, await unwrap(envOf(args).openBinaryReader(args.path, { noFollow: args.noFollow === true }, context))),
	"binaryReader.info": (args, context) => unwrap(handle<BinaryReader>(args.reader).info(context)),
	"binaryReader.read": async (args, context) => toBase64(await unwrap(handle<BinaryReader>(args.reader).read(args.offset, args.length, context))),
	"binaryReader.scanLines": (args, context) =>
		unwrap(
			handle<BinaryReader>(args.reader).scanLines(
				{ startLine: args.startLine, ...(args.endLine == null ? {} : { endLine: args.endLine }) },
				context,
			),
		),
	"binaryReader.close": async (args, context) => {
		await handle<BinaryReader>(args.reader).close(context);
		closeHandle(args.reader);
	},
	"env.openDirReader": async (args, context) => openChild(args, await unwrap(envOf(args).openDirReader(args.path, context))),
	"dirReader.next": (args, context) => unwrap(handle<DirReader>(args.reader).next(args.maxEntries, context)),
	"dirReader.close": async (args, context) => {
		await handle<DirReader>(args.reader).close(context);
		closeHandle(args.reader);
	},
	"env.openTextLineReader": async (args, context) => openChild(args, await unwrap(envOf(args).openTextLineReader(args.path, context))),
	"lineReader.next": async (args, context) => (await unwrap(handle<TextLineReader>(args.reader).readLine(context))) ?? null,
	"lineReader.close": async (args, context) => {
		await handle<TextLineReader>(args.reader).close(context);
		closeHandle(args.reader);
	},

	// Streams

	/** Runs a command: emits `{ text, stream }` per output chunk, then `{ exitCode, spillPath }`. */
	"env.exec": (args) => {
		const env = envOf(args);
		const controller = new AbortController();
		const stream = args.stream as number;
		openStream(stream, () => controller.abort());
		void (async () => {
			const result = await env.exec(
				args.command,
				{
					...(args.cwd == null ? {} : { cwd: args.cwd }),
					...(args.environment == null ? {} : { env: args.environment }),
					...(args.inheritEnv == null ? {} : { inheritEnv: args.inheritEnv }),
					...(args.timeout == null ? {} : { timeout: args.timeout }),
					...(args.spill == null ? {} : { spill: args.spill }),
					...(args.window == null ? {} : { window: args.window }),
					onOutput: (text, _context, info) => emit(stream, { text, stream: info.stream, skipped: info.skipped ?? null }),
				},
				contextOf(controller.signal),
			);
			if (result.ok) {
				emit(stream, { exitCode: result.value.exitCode, spillPath: result.value.spillPath ?? null });
				finish(stream);
			} else {
				finish(stream, result.error);
			}
		})().catch((error) => finish(stream, error));
	},
	/** Watches files: emits each `WatchChange`; the stream ends when the watcher stops. */
	"env.watch": async (args, context) => {
		const stream = args.stream as number;
		const watcher = await unwrap(
			envOf(args).watch(
				args.targets,
				(change) => {
					if ("error" in change) finish(stream, change.error);
					else emit(stream, change);
				},
				context,
			),
		);
		openStream(stream, () => watcher.close(contextOf(undefined)));
		emit(stream, { mode: watcher.mode });
	},
});
