// Execution environments: a virtual file system and optional shell over a backend, for pi-durable's tools, JSONL
// storage, and Swift code. Paths are virtual and absolute (`/notes/todo.md`), normalized against `cwd`; `..` never
// climbs above `/`.
//
// Two backends: `NativeBackend`, a sandbox rooted at one host directory (the model never sees the app's container paths
// and cannot leave the directory; a shell runs there only when Swift enables it, on macOS), and `HostBackend`, an
// environment implemented in Swift (`CustomExecutionEnvironment`).
import type { Context } from "@earendil-works/chord";
import {
	type BinaryReader,
	type DirReader,
	ExecutionError,
	type ExecutionErrorCode,
	type ExecutionEnv,
	err,
	FileError,
	type FileErrorCode,
	type FileInfo,
	type FileListEntry,
	type FileListing,
	type FileWatcher,
	type ListFilesOptions,
	LineScanner,
	type LineScan,
	ok,
	type Result,
	type ShellExecOptions,
	type ShellExecResult,
	type TextLine,
	type TextLineReader,
	type WatchChange,
	type WatchTarget,
} from "@earendil-works/pi-durable/env";
import { type Args, host, register } from "./core.ts";
import { native } from "../runtime/native.ts";

/** One opened file of a backend. */
export interface OpenedFile {
	info(): Promise<NativeInfo>;
	read(offset: number, length: number): Promise<Uint8Array>;
	close(): Promise<void>;
}

export type NativeInfo = { name: string; kind: "file" | "directory" | "symlink"; size: number; mtimeMs: number };

/** One command for a backend's shell: a string for the shell, or an argv array run directly. */
export type ShellCommand = { command: string | readonly string[]; cwd: string; env?: Record<string, string>; inheritEnv?: boolean; timeout?: number };

/** File and process primitives over virtual, normalized, absolute paths. Failures throw errors with a `code`. */
export interface EnvBackend {
	readonly id: string;
	/** Whether `write` creates missing parent directories itself; otherwise the environment creates them first. */
	readonly createsParents?: boolean;
	stat(path: string, follow: boolean): Promise<NativeInfo>;
	read(path: string): Promise<Uint8Array>;
	readRange(path: string, offset: number, length: number): Promise<Uint8Array>;
	write(path: string, content: string | Uint8Array, append: boolean): Promise<void>;
	truncate(path: string, size: number): Promise<void>;
	sync(path: string): Promise<void>;
	rename(source: string, destination: string): Promise<void>;
	list(path: string): Promise<NativeInfo[]>;
	mkdir(path: string, recursive: boolean): Promise<void>;
	remove(path: string, recursive: boolean, force: boolean): Promise<void>;
	/** The canonical virtual path; throws `permission_denied` when it leaves the file system. */
	realpath(path: string): Promise<string>;
	/**
	 * Opens a regular file whose reads keep seeing it after a rename; absent: the file is read whole when opened.
	 * Fails with `is_directory` or `invalid` for other kinds.
	 */
	open?(path: string, noFollow: boolean): Promise<OpenedFile>;
	/** Runs a command, delivering output chunks; absent when there is no shell. */
	exec?(
		command: ShellCommand,
		onOutput: (text: string, stream: "stdout" | "stderr") => void,
		context: Context,
	): Promise<{ exitCode: number }>;
	/** Releases the backend's resources. */
	cleanup?(): Promise<void>;
}

const encoder = new TextEncoder();

/** Normalizes a virtual path against `cwd`; `..` never climbs above the root. */
export function normalize(path: string, cwd = "/"): string {
	const parts: string[] = [];
	for (const part of (path.startsWith("/") ? path : `${cwd}/${path}`).split("/")) {
		if (part === "" || part === ".") continue;
		if (part === "..") parts.pop();
		else parts.push(part);
	}
	return `/${parts.join("/")}`;
}

function fileError(error: unknown, path: string): FileError {
	if (error instanceof FileError) return error;
	const code = ((error as { code?: string }).code ?? "unknown") as FileErrorCode;
	const message = error instanceof Error ? error.message : String(error);
	return new FileError(code, message, path);
}

function aborted(context: Context | undefined, path: string): Result<never, FileError> | undefined {
	return context?.abortSignal?.aborted ? err(new FileError("aborted", "Operation aborted", path)) : undefined;
}

let tempCounter = 0;

/** pi-durable's `ExecutionEnv` over a backend. */
export class BackendEnv implements ExecutionEnv {
	readonly id: string;
	cwd: string;
	readonly backend: EnvBackend;

	constructor(backend: EnvBackend, cwd = "/") {
		this.backend = backend;
		this.id = backend.id;
		this.cwd = normalize(cwd);
	}

	#path(path: string): string {
		return normalize(path, this.cwd);
	}

	async #run<T>(path: string, context: Context | undefined, body: (path: string) => Promise<T>): Promise<Result<T, FileError>> {
		const stop = aborted(context, path);
		if (stop) return stop;
		const absolute = this.#path(path);
		try {
			return ok(await body(absolute));
		} catch (error) {
			return err(fileError(error, absolute));
		}
	}

	async #info(path: string, follow = true): Promise<FileInfo> {
		const absolute = this.#path(path);
		const info = await this.backend.stat(absolute, follow);
		return { name: absolute.split("/").pop() || "/", path: absolute, kind: info.kind, size: info.size, mtimeMs: info.mtimeMs };
	}

	async absolutePath(path: string): Promise<Result<string, FileError>> {
		return ok(this.#path(path));
	}

	async joinPath(parts: string[]): Promise<Result<string, FileError>> {
		return ok(normalize(parts.join("/"), "/"));
	}

	async readTextFile(path: string, context: Context): Promise<Result<string, FileError>> {
		return this.#run(path, context, async (absolute) => new TextDecoder().decode(await this.backend.read(absolute)));
	}

	async readTextLines(path: string, options: { maxLines?: number } | undefined, context: Context): Promise<Result<string[], FileError>> {
		const text = await this.readTextFile(path, context);
		if (!text.ok) return text;
		const lines = text.value.split(/\r?\n/);
		if (lines.at(-1) === "") lines.pop();
		return ok(options?.maxLines === undefined ? lines : lines.slice(0, options.maxLines));
	}

	async openTextLineReader(path: string, context: Context): Promise<Result<TextLineReader, FileError>> {
		const text = await this.readTextFile(path, context);
		if (!text.ok) return text;
		const pieces = text.value.split("\n");
		let index = 0;
		return ok({
			readLine: async (): Promise<Result<TextLine | undefined, FileError>> => {
				while (index < pieces.length) {
					const terminated = index < pieces.length - 1;
					const value = pieces[index++]!;
					if (!terminated && value === "") return ok(undefined);
					return ok({ text: value.replace(/\r$/, ""), terminated });
				}
				return ok(undefined);
			},
			close: async () => {},
		});
	}

	async readBinaryFile(path: string, context: Context): Promise<Result<Uint8Array, FileError>> {
		return this.#run(path, context, (absolute) => this.backend.read(absolute));
	}

	async openBinaryReader(path: string, options: { noFollow?: boolean } | undefined, context: Context): Promise<Result<BinaryReader, FileError>> {
		const noFollow = options?.noFollow === true;
		const opened = await this.#run(path, context, async (absolute): Promise<OpenedFile> => {
			if (this.backend.open !== undefined) return this.backend.open(absolute, noFollow);
			// Without descriptors, the reader keeps the file as it was when opened.
			const info = await this.backend.stat(absolute, !noFollow);
			if (info.kind === "directory") throw Object.assign(new Error(`${absolute}: is a directory`), { code: "is_directory" });
			if (info.kind !== "file") throw Object.assign(new Error(`${absolute}: not a regular file`), { code: "invalid" });
			const bytes = await this.backend.read(absolute);
			return {
				info: async () => ({ ...info, size: bytes.byteLength }),
				read: async (offset, length) => bytes.slice(offset, offset + length),
				close: async () => {},
			};
		});
		if (!opened.ok) return opened;
		const absolute = this.#path(path);
		const file = opened.value;
		let closed = false;
		const closedError = () => err<never, FileError>(new FileError("invalid", "Binary reader is closed", absolute));
		const run = <T>(context: Context, body: () => Promise<T>) => this.#run(absolute, context, body);
		return ok({
			info: async (context: Context) =>
				closed
					? closedError()
					: run(context, async () => {
							const info = await file.info();
							return { name: absolute.split("/").pop() || "/", path: absolute, kind: info.kind, size: info.size, mtimeMs: info.mtimeMs };
						}),
			read: async (offset: number, length: number, context: Context) => {
				if (closed) return closedError();
				if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0) {
					return err(new FileError("invalid", "Invalid byte range", absolute));
				}
				return run(context, () => file.read(offset, length));
			},
			scanLines: async (options: { startLine: number; endLine?: number }, context: Context): Promise<Result<LineScan, FileError>> => {
				if (closed) return closedError();
				let scanner: LineScanner;
				try {
					scanner = new LineScanner(options.startLine, options.endLine);
				} catch {
					return err(new FileError("invalid", "Invalid line range", absolute));
				}
				for (let position = 0; ; ) {
					const chunk = await run(context, () => file.read(position, 64 * 1024));
					if (!chunk.ok) return chunk;
					if (chunk.value.byteLength === 0) return ok(scanner.finish());
					scanner.push(chunk.value);
					position += chunk.value.byteLength;
				}
			},
			close: async () => {
				if (closed) return;
				closed = true;
				await file.close();
			},
		});
	}

	/** Writes or appends, creating missing parent directories like pi-durable's Node environment. */
	async #write(absolute: string, content: string | Uint8Array, append: boolean): Promise<void> {
		if (this.backend.createsParents !== true) {
			const parent = absolute.slice(0, absolute.lastIndexOf("/")) || "/";
			if (parent !== "/") await this.backend.mkdir(parent, true);
		}
		await this.backend.write(absolute, content, append);
	}

	async writeFile(path: string, content: string | Uint8Array, context: Context): Promise<Result<void, FileError>> {
		return this.#run(path, context, (absolute) => this.#write(absolute, content, false));
	}

	async appendFile(path: string, content: string | Uint8Array, context: Context): Promise<Result<void, FileError>> {
		return this.#run(path, context, (absolute) => this.#write(absolute, content, true));
	}

	async truncateFile(path: string, size: number, context: Context): Promise<Result<void, FileError>> {
		return this.#run(path, context, (absolute) => this.backend.truncate(absolute, size));
	}

	async flushFile(path: string, context: Context): Promise<Result<void, FileError>> {
		return this.#run(path, context, (absolute) => this.backend.sync(absolute));
	}

	async renameFile(sourcePath: string, destinationPath: string, context: Context): Promise<Result<void, FileError>> {
		return this.#run(sourcePath, context, (absolute) => this.backend.rename(absolute, this.#path(destinationPath)));
	}

	async fileInfo(path: string, context: Context): Promise<Result<FileInfo, FileError>> {
		return this.#run(path, context, () => this.#info(path, false));
	}

	async listDir(path: string, context: Context): Promise<Result<FileInfo[], FileError>> {
		return this.#run(path, context, async (directory) =>
			(await this.backend.list(directory)).map((entry) => ({
				name: entry.name,
				path: normalize(entry.name, directory),
				kind: entry.kind,
				size: entry.size,
				mtimeMs: entry.mtimeMs,
			})),
		);
	}

	async openDirReader(path: string, context: Context): Promise<Result<DirReader, FileError>> {
		const listed = await this.#run(path, context, async (directory) => {
			const info = await this.backend.stat(directory, true);
			if (info.kind !== "directory") throw Object.assign(new Error(`${directory}: not a directory`), { code: "not_directory" });
			return { directory, names: (await this.backend.list(directory)).map((entry) => entry.name) };
		});
		if (!listed.ok) return listed;
		const { directory, names } = listed.value;
		let offset = 0;
		let closed = false;
		return ok({
			next: async (maxEntries: number, context: Context) => {
				if (closed) return err(new FileError("invalid", "Directory reader is closed", directory));
				if (!Number.isSafeInteger(maxEntries) || maxEntries < 1) return err(new FileError("invalid", "maxEntries must be a positive integer", directory));
				const stopped = aborted(context, directory);
				if (stopped) return stopped;
				const entries: FileInfo[] = [];
				// Entries are described when reached, so one removed meanwhile is skipped.
				while (offset < names.length && entries.length < maxEntries) {
					const child = normalize(names[offset++]!, directory);
					const stop = aborted(context, child);
					if (stop) return stop;
					try {
						const info = await this.backend.stat(child, false);
						entries.push({ name: names[offset - 1]!, path: child, kind: info.kind, size: info.size, mtimeMs: info.mtimeMs });
					} catch (error) {
						if ((error as { code?: string }).code === "not_found") continue;
						return err(fileError(error, child));
					}
				}
				return ok({ entries, done: offset >= names.length });
			},
			close: async () => {
				closed = true;
			},
		});
	}

	/**
	 * Polls the watched trees about once a second: `polling` mode, since neither backend reports changes itself. A change
	 * undone between two snapshots can be missed.
	 */
	async watch(
		targets: readonly WatchTarget[],
		onChange: (change: WatchChange) => void,
		context: Context,
	): Promise<Result<FileWatcher, FileError>> {
		const stop = aborted(context, targets[0]?.path ?? "/");
		if (stop) return stop;
		const resolved = targets.map((target) => ({ ...target, path: this.#path(target.path) }));
		const snapshot = async () => {
			const files = new Map<string, string>();
			for (const target of resolved) await this.#snapshot(target, target.path, files, true);
			return files;
		};
		let previous: Map<string, string>;
		try {
			previous = await snapshot();
		} catch (error) {
			return err(fileError(error, resolved[0]?.path ?? "/"));
		}
		let closed = false;
		let timer: ReturnType<typeof setTimeout> | undefined;
		const poll = async () => {
			if (closed) return;
			try {
				const next = await snapshot();
				const changed = new Set<string>();
				for (const [path, stamp] of next) if (previous.get(path) !== stamp) changed.add(path);
				for (const path of previous.keys()) if (!next.has(path)) changed.add(path);
				previous = next;
				if (!closed && changed.size > 0) onChange({ paths: [...changed].sort() });
			} catch (error) {
				if (closed) return;
				closed = true;
				onChange({ error: fileError(error, resolved[0]?.path ?? "/") });
				return;
			}
			if (!closed) timer = setTimeout(poll, 1000);
		};
		timer = setTimeout(poll, 1000);
		return ok({
			mode: "polling",
			close: async () => {
				closed = true;
				if (timer !== undefined) clearTimeout(timer);
			},
		});
	}

	async #snapshot(target: WatchTarget, path: string, files: Map<string, string>, top: boolean): Promise<void> {
		let info: NativeInfo;
		try {
			// A watched path that is a symbolic link reports changes to what it points to.
			info = await this.backend.stat(path, top);
		} catch (error) {
			if ((error as { code?: string }).code === "not_found") return;
			throw error;
		}
		files.set(path, `${info.kind}:${info.size}:${info.mtimeMs}`);
		if (info.kind !== "directory" || (!top && target.recursive !== true)) return;
		for (const entry of await this.backend.list(path)) {
			if (target.exclude?.hidden && entry.name.startsWith(".")) continue;
			if (target.exclude?.names?.includes(entry.name)) continue;
			const child = normalize(entry.name, path);
			if (target.recursive === true && entry.kind === "directory") await this.#snapshot(target, child, files, false);
			else files.set(child, `${entry.kind}:${entry.size}:${entry.mtimeMs}`);
		}
	}

	/**
	 * Every file, directory, and symbolic link below a directory, depth first with siblings in name order, skipping
	 * `.git`, hidden names unless `hidden`, `exclude` names, and inside a git work tree what its ignore files ignore.
	 */
	async listFiles(path: string, options: ListFilesOptions | undefined, context: Context): Promise<Result<FileListing, FileError>> {
		const absolute = this.#path(path);
		const invalid = (message: string) => err<never, FileError>(new FileError("invalid", message, absolute));
		const maxEntries = options?.maxEntries ?? 50_000;
		const maxBytes = options?.maxBytes ?? 4 * 1024 * 1024;
		const timeoutMs = options?.timeoutMs ?? 10_000;
		if (!Number.isSafeInteger(maxEntries) || maxEntries < 0) return invalid("maxEntries must be a non-negative integer");
		if (!Number.isSafeInteger(maxBytes) || maxBytes < 0 || maxBytes > 15.9 * 1024 * 1024) return invalid("maxBytes is out of range");
		if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 0) return invalid("timeoutMs must be a non-negative integer");
		const stop = aborted(context, absolute);
		if (stop) return stop;
		return this.#run(absolute, context, async () => {
			const root = await this.backend.stat(absolute, true);
			if (root.kind !== "directory") throw Object.assign(new Error(`${absolute}: not a directory`), { code: "not_directory" });
			const hidden = options?.hidden !== false;
			const excluded = new Set(options?.exclude ?? []);
			const ignore = options?.gitignore === false ? undefined : await this.#ignoreRules(absolute);
			const deadline = Date.now() + timeoutMs;
			const entries: FileListEntry[] = [];
			let bytes = 0;
			let truncated = false;
			const walk = async (directory: string, relative: string, rules: IgnoreRules | undefined): Promise<boolean> => {
				if (context.abortSignal?.aborted) throw Object.assign(new Error("Operation aborted"), { code: "aborted" });
				let children: NativeInfo[];
				try {
					children = await this.backend.list(directory);
				} catch (error) {
					if (relative === "") throw error;
					return true; // Entries that cannot be read are skipped.
				}
				children.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
				const local = rules === undefined ? undefined : await rules.descend(directory, this.backend);
				for (const child of children) {
					if (child.name === ".git" || excluded.has(child.name)) continue;
					if (!hidden && child.name.startsWith(".")) continue;
					const path = relative === "" ? child.name : `${relative}/${child.name}`;
					const full = normalize(child.name, directory);
					if (local?.ignores(full, child.kind === "directory")) continue;
					const size = utf8Length(path) + 2;
					if (entries.length >= maxEntries || bytes + size > maxBytes || Date.now() > deadline) {
						truncated = true;
						return false;
					}
					entries.push({ path, kind: child.kind });
					bytes += size;
					if (child.kind === "directory" && !(await walk(full, path, local))) return false;
				}
				return true;
			};
			await walk(absolute, "", ignore);
			return { entries, truncated };
		});
	}

	/** The ignore rules in effect at `directory` when it is inside a git work tree. */
	async #ignoreRules(directory: string): Promise<IgnoreRules | undefined> {
		const exists = async (path: string) => {
			try {
				await this.backend.stat(path, false);
				return true;
			} catch {
				return false;
			}
		};
		let top: string | undefined;
		for (let candidate = directory; ; candidate = parentOf(candidate)) {
			if (await exists(normalize(".git", candidate))) {
				top = candidate;
				break;
			}
			if (candidate === "/") break;
		}
		if (top === undefined) return undefined;
		let rules = new IgnoreRules(top, []);
		rules = rules.with(top, await readIgnoreFile(this.backend, normalize(".git/info/exclude", top)));
		// The parents' `.gitignore` files, from the work tree's top down to the listed directory's parent; the listed
		// directory's own is added when the walk enters it.
		const parents: string[] = [];
		for (let candidate = directory; candidate !== top; ) {
			candidate = parentOf(candidate);
			parents.unshift(candidate);
		}
		for (const parent of parents) rules = await rules.descend(parent, this.backend);
		return rules;
	}

	async canonicalPath(path: string, context: Context): Promise<Result<string, FileError>> {
		return this.#run(path, context, (absolute) => this.backend.realpath(absolute));
	}

	async exists(path: string, context: Context): Promise<Result<boolean, FileError>> {
		return this.#run(path, context, async (absolute) => {
			try {
				await this.backend.stat(absolute, false);
				return true;
			} catch (error) {
				if ((error as { code?: string }).code === "not_found") return false;
				throw error;
			}
		});
	}

	async createDir(path: string, options: { recursive?: boolean } | undefined, context: Context): Promise<Result<void, FileError>> {
		return this.#run(path, context, (absolute) => this.backend.mkdir(absolute, options?.recursive === true));
	}

	async remove(path: string, options: { recursive?: boolean; force?: boolean } | undefined, context: Context): Promise<Result<void, FileError>> {
		if (this.#path(path) === "/") return err(new FileError("permission_denied", "Cannot remove the root", "/"));
		return this.#run(path, context, (absolute) => this.backend.remove(absolute, options?.recursive === true, options?.force === true));
	}

	#tempName(prefix: string | undefined, suffix = ""): string {
		return `/.tmp/${prefix ?? "tmp"}${Date.now().toString(36)}${(tempCounter++).toString(36)}${suffix}`;
	}

	async createTempDir(prefix: string | undefined, context: Context): Promise<Result<string, FileError>> {
		const path = this.#tempName(prefix);
		const created = await this.createDir(path, { recursive: true }, context);
		return created.ok ? ok(path) : created;
	}

	async createTempFile(options: { prefix?: string; suffix?: string } | undefined, context: Context): Promise<Result<string, FileError>> {
		const directory = await this.createDir("/.tmp", { recursive: true }, context);
		if (!directory.ok) return directory;
		const path = this.#tempName(options?.prefix, options?.suffix);
		const written = await this.writeFile(path, encoder.encode(""), context);
		return written.ok ? ok(path) : written;
	}

	async exec(
		command: string | readonly string[],
		options: ShellExecOptions | undefined,
		context: Context,
	): Promise<Result<ShellExecResult, ExecutionError>> {
		if (Array.isArray(command) && command.length === 0) return err(new ExecutionError("spawn_error", "Empty argv: no program to run"));
		const exec = this.backend.exec?.bind(this.backend);
		if (exec === undefined) return err(new ExecutionError("shell_unavailable", "There is no shell in this environment"));
		if (options?.timeout !== undefined && (!Number.isFinite(options.timeout) || options.timeout <= 0)) {
			return err(new ExecutionError("timeout", "Invalid timeout: must be a finite number of seconds"));
		}
		if (context.abortSignal?.aborted) return err(new ExecutionError("aborted", "Command aborted"));
		// The complete output goes to a spill file once it crosses either threshold.
		const spill = options?.spill;
		let spillPath: string | undefined;
		let spillWrites = Promise.resolve();
		let buffered: string[] = [];
		let bytes = 0;
		let lines = 0;
		const record = (text: string) => {
			if (spill === undefined) return;
			if (spillPath !== undefined) {
				const path = spillPath;
				spillWrites = spillWrites.then(() => this.backend.write(path, text, true)).catch(() => undefined);
				return;
			}
			buffered.push(text);
			bytes += encoder.encode(text).byteLength;
			for (const char of text) if (char === "\n") lines++;
			if (bytes > spill.afterBytes || lines + 1 > spill.afterLines) {
				const path = this.#tempName("output-", ".log");
				spillPath = path;
				const all = buffered.join("");
				buffered = [];
				spillWrites = spillWrites
					.then(() => this.backend.mkdir("/.tmp", true))
					.then(() => this.backend.write(path, all, false))
					.catch(() => undefined);
			}
		};
		let callbackError: unknown;
		try {
			const result = await exec(
				{
					command,
					cwd: this.#path(options?.cwd ?? this.cwd),
					...(options?.env === undefined ? {} : { env: options.env }),
					...(options?.inheritEnv === undefined ? {} : { inheritEnv: options.inheritEnv }),
					...(options?.timeout === undefined ? {} : { timeout: options.timeout }),
				},
				(text, stream) => {
					record(text);
					if (callbackError !== undefined) return;
					try {
						options?.onOutput?.(text, context, { stream });
					} catch (error) {
						callbackError = error;
					}
				},
				context,
			);
			await spillWrites;
			if (callbackError !== undefined) {
				return err(new ExecutionError("callback_error", callbackError instanceof Error ? callbackError.message : String(callbackError)));
			}
			return ok({ exitCode: result.exitCode, ...(spillPath === undefined ? {} : { spillPath }) });
		} catch (error) {
			await spillWrites;
			const code = (context.abortSignal?.aborted ? "aborted" : ((error as { code?: string }).code ?? "unknown")) as ExecutionErrorCode;
			const failure = new ExecutionError(code, error instanceof Error ? error.message : String(error));
			if (spillPath !== undefined) failure.spillPath = spillPath;
			return err(failure);
		}
	}

	async cleanup(): Promise<void> {
		await this.backend.cleanup?.();
	}
}

// MARK: Native sandbox

/** Output chunks of running host commands, by exec ID; Swift pushes them with `env.output`. */
const outputs = new Map<number, (text: string, stream: "stdout" | "stderr") => void>();
let nextExec = 1;

/** Runs a command through Swift (a `Process` on macOS), streaming output back through `env.output`. */
export async function hostExec(
	method: string,
	args: Args,
	command: ShellCommand,
	onOutput: (text: string, stream: "stdout" | "stderr") => void,
	context: Context,
): Promise<{ exitCode: number }> {
	const exec = nextExec++;
	outputs.set(exec, onOutput);
	try {
		return await host<{ exitCode: number }>(method, { ...args, exec, command }, context);
	} finally {
		outputs.delete(exec);
	}
}

register({
	"env.output": (args) => {
		outputs.get(args.exec)?.(args.text, args.stream);
	},
});

/** A sandbox rooted at one host directory, through the runtime's native file functions. */
export class NativeBackend implements EnvBackend {
	readonly id: string;
	readonly createsParents = true;
	readonly #root: string;
	readonly #shell: boolean;

	/**
	 * - Parameter root: the host directory that is `/` in the sandbox.
	 * - Parameter shell: whether commands run (in the sandbox's real directory), which Swift supports on macOS.
	 */
	constructor(root: string, shell = false) {
		this.#root = root.replace(/\/+$/, "");
		// The root `/` is the host's own file system, which every such environment shares.
		this.id = this.#root === "" ? "local" : `sandbox:${this.#root}`;
		this.#shell = shell;
		if (!shell) (this as { exec?: unknown }).exec = undefined;
	}

	#real(path: string): string {
		return this.#root + path;
	}

	#virtual(real: string): string | undefined {
		if (real === this.#root) return "/";
		return real.startsWith(`${this.#root}/`) ? real.slice(this.#root.length) : undefined;
	}

	/** Runs a native call; errors show host paths under the root as sandbox paths. */
	#native<T>(body: () => T): Promise<T> {
		try {
			return Promise.resolve(body());
		} catch (error) {
			const message = (error instanceof Error ? error.message : String(error)).replaceAll(this.#root, "");
			return Promise.reject(Object.assign(new Error(message), { code: (error as { code?: string }).code ?? "unknown" }));
		}
	}

	stat(path: string, follow: boolean): Promise<NativeInfo> {
		return this.#native(() => JSON.parse(native.fsStat(this.#real(path), follow)) as NativeInfo);
	}
	read(path: string): Promise<Uint8Array> {
		return this.#native(() => native.fsReadFile(this.#real(path)));
	}
	readRange(path: string, offset: number, length: number): Promise<Uint8Array> {
		return this.#native(() => native.fsReadRange(this.#real(path), offset, length));
	}
	write(path: string, content: string | Uint8Array, append: boolean): Promise<void> {
		return this.#native(() => native.fsWrite(this.#real(path), content, append));
	}
	truncate(path: string, size: number): Promise<void> {
		return this.#native(() => native.fsTruncate(this.#real(path), size));
	}
	sync(path: string): Promise<void> {
		return this.#native(() => native.fsSync(this.#real(path)));
	}
	rename(source: string, destination: string): Promise<void> {
		return this.#native(() => native.fsRename(this.#real(source), this.#real(destination)));
	}
	list(path: string): Promise<NativeInfo[]> {
		return this.#native(() => JSON.parse(native.fsList(this.#real(path))) as NativeInfo[]);
	}
	mkdir(path: string, recursive: boolean): Promise<void> {
		return this.#native(() => native.fsMkdir(this.#real(path), recursive));
	}
	remove(path: string, recursive: boolean, force: boolean): Promise<void> {
		return this.#native(() => native.fsRemove(this.#real(path), recursive, force));
	}
	realpath(path: string): Promise<string> {
		return this.#native(() => {
			const resolved = this.#virtual(native.fsRealpath(this.#real(path)));
			if (resolved === undefined) throw Object.assign(new Error("Path resolves outside the sandbox"), { code: "permission_denied" });
			return resolved;
		});
	}
	open(path: string, noFollow: boolean): Promise<OpenedFile> {
		return this.#native(() => {
			const descriptor = native.fsOpen(this.#real(path), noFollow);
			const name = path.split("/").pop() || "/";
			let open = true;
			return {
				info: () => this.#native(() => JSON.parse(native.fsFstat(descriptor, name)) as NativeInfo),
				read: (offset: number, length: number) => this.#native(() => native.fsReadAt(descriptor, offset, length)),
				close: async () => {
					if (open) native.fsClose(descriptor);
					open = false;
				},
			} satisfies OpenedFile;
		});
	}
	exec(command: ShellCommand, onOutput: (text: string, stream: "stdout" | "stderr") => void, context: Context): Promise<{ exitCode: number }> {
		if (!this.#shell) return Promise.reject(Object.assign(new Error("There is no shell in this environment"), { code: "shell_unavailable" }));
		return hostExec("env.shell", { root: this.#root }, { ...command, cwd: this.#real(command.cwd) }, onOutput, context);
	}
}

/** The sandbox environment of `root`, with a shell when `shell` is set. */
export class SandboxEnv extends BackendEnv {
	constructor(root: string, cwd = "/", shell = false) {
		super(new NativeBackend(root, shell), cwd);
	}
}

// MARK: Environments implemented in Swift

function toBase64(bytes: Uint8Array): string {
	let binary = "";
	for (let index = 0; index < bytes.length; index += 0x8000) {
		binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
	}
	return btoa(binary);
}

function fromBase64(text: string): Uint8Array {
	return Uint8Array.from(atob(text), (char) => char.charCodeAt(0));
}

export { fromBase64, toBase64 };

/** An environment Swift implements (`CustomExecutionEnvironment`), by its registration number. */
export class HostBackend implements EnvBackend {
	readonly id: string;
	readonly #environment: string;
	readonly #shell: boolean;

	/** - Parameter environment: the environment's registration key in Swift, its `id`. */
	constructor(environment: string, id: string, shell: boolean) {
		this.#environment = environment;
		this.id = id;
		this.#shell = shell;
		if (!shell) (this as { exec?: unknown }).exec = undefined;
	}

	#call<T>(operation: string, args: Args): Promise<T> {
		return host<T>("env.custom", { environment: this.#environment, operation, ...args });
	}

	stat(path: string, follow: boolean): Promise<NativeInfo> {
		return this.#call("stat", { path, follow });
	}
	async read(path: string): Promise<Uint8Array> {
		return fromBase64(await this.#call<string>("read", { path }));
	}
	async readRange(path: string, offset: number, length: number): Promise<Uint8Array> {
		return fromBase64(await this.#call<string>("readRange", { path, offset, length }));
	}
	write(path: string, content: string | Uint8Array, append: boolean): Promise<void> {
		const bytes = typeof content === "string" ? encoder.encode(content) : content;
		return this.#call("write", { path, data: toBase64(bytes), append });
	}
	truncate(path: string, size: number): Promise<void> {
		return this.#call("truncate", { path, size });
	}
	sync(path: string): Promise<void> {
		return this.#call("sync", { path });
	}
	rename(source: string, destination: string): Promise<void> {
		return this.#call("rename", { path: source, destination });
	}
	list(path: string): Promise<NativeInfo[]> {
		return this.#call("list", { path });
	}
	mkdir(path: string, recursive: boolean): Promise<void> {
		return this.#call("mkdir", { path, recursive });
	}
	remove(path: string, recursive: boolean, force: boolean): Promise<void> {
		return this.#call("remove", { path, recursive, force });
	}
	realpath(path: string): Promise<string> {
		return this.#call("realpath", { path });
	}
	exec(command: ShellCommand, onOutput: (text: string, stream: "stdout" | "stderr") => void, context: Context): Promise<{ exitCode: number }> {
		if (!this.#shell) return Promise.reject(Object.assign(new Error("There is no shell in this environment"), { code: "shell_unavailable" }));
		return hostExec("env.custom", { environment: this.#environment, operation: "exec" }, command, onOutput, context);
	}
	cleanup(): Promise<void> {
		return this.#call("cleanup", {});
	}
}

/** Builds the environment Swift describes: `{ root, shell }` (a sandbox) or `{ custom, id, shell }` (Swift's own). */
export function environmentOf(spec: Args, cwd: string | undefined): ExecutionEnv {
	if (typeof spec.custom === "string") return new BackendEnv(new HostBackend(spec.custom, spec.id, spec.shell === true), cwd ?? spec.cwd ?? "/");
	return new SandboxEnv(spec.root, cwd ?? "/", spec.shell === true);
}

// MARK: Ignore files

function parentOf(path: string): string {
	return path.slice(0, path.lastIndexOf("/")) || "/";
}

function utf8Length(text: string): number {
	return encoder.encode(text).byteLength;
}

async function readIgnoreFile(backend: EnvBackend, path: string): Promise<string> {
	try {
		return new TextDecoder().decode(await backend.read(path));
	} catch {
		return "";
	}
}

type IgnoreRule = { readonly base: string; readonly regex: RegExp; readonly negate: boolean; readonly directoryOnly: boolean; readonly anchored: boolean };

/** A glob of an ignore file as a regular expression over `/`-separated paths. */
function globSource(glob: string): string {
	let source = "";
	for (let index = 0; index < glob.length; index++) {
		const char = glob[index]!;
		if (char === "*") {
			if (glob[index + 1] === "*") {
				const atStart = index === 0 || glob[index - 1] === "/";
				const atEnd = index + 2 === glob.length || glob[index + 2] === "/";
				if (atStart && atEnd) {
					if (index + 2 === glob.length) source += ".*";
					else {
						source += "(?:.*/)?";
						index++;
					}
					index++;
					continue;
				}
				index++;
			}
			source += "[^/]*";
		} else if (char === "?") source += "[^/]";
		else if (char === "[") {
			const close = glob.indexOf("]", index + 2);
			if (close === -1) source += "\\[";
			else {
				let body = glob.slice(index + 1, close).replace(/\\/g, "\\\\");
				if (body.startsWith("!")) body = `^${body.slice(1)}`;
				source += `[${body}]`;
				index = close;
			}
		} else if (char === "\\" && index + 1 < glob.length) source += `\\${glob[++index]}`;
		else source += char.replace(/[.+^${}()|\]\\/]/g, "\\$&");
	}
	return source;
}

function parseIgnore(base: string, text: string): IgnoreRule[] {
	const rules: IgnoreRule[] = [];
	for (let line of text.split(/\r?\n/)) {
		if (line === "" || line.startsWith("#")) continue;
		line = line.replace(/(?<!\\)\s+$/, "");
		if (line === "") continue;
		let negate = false;
		if (line.startsWith("!")) {
			negate = true;
			line = line.slice(1);
		} else if (line.startsWith("\\!") || line.startsWith("\\#")) line = line.slice(1);
		const directoryOnly = line.endsWith("/");
		if (directoryOnly) line = line.slice(0, -1);
		const anchored = line.includes("/");
		if (line.startsWith("/")) line = line.slice(1);
		if (line === "") continue;
		rules.push({ base, regex: new RegExp(`^${globSource(line)}$`), negate, directoryOnly, anchored });
	}
	return rules;
}

/** The ignore rules of a work tree in effect at one directory, lowest precedence first; the last match wins. */
class IgnoreRules {
	constructor(
		readonly top: string,
		readonly rules: readonly IgnoreRule[],
	) {}

	with(base: string, text: string): IgnoreRules {
		const added = parseIgnore(base, text);
		return added.length === 0 ? this : new IgnoreRules(this.top, [...this.rules, ...added]);
	}

	/** These rules with `directory`'s own `.gitignore` added. */
	async descend(directory: string, backend: EnvBackend): Promise<IgnoreRules> {
		return this.with(directory, await readIgnoreFile(backend, normalize(".gitignore", directory)));
	}

	ignores(path: string, isDirectory: boolean): boolean {
		let ignored = false;
		for (const rule of this.rules) {
			if (rule.directoryOnly && !isDirectory) continue;
			if (!(path === rule.base || path.startsWith(rule.base === "/" ? "/" : `${rule.base}/`))) continue;
			const relative = path.slice(rule.base === "/" ? 1 : rule.base.length + 1);
			const subject = rule.anchored ? relative : relative.slice(relative.lastIndexOf("/") + 1);
			if (rule.regex.test(subject)) ignored = !rule.negate;
		}
		return ignored;
	}
}
