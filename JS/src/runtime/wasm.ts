// WebAssembly's promise APIs settle through JavaScriptCore's deferred work, which runs on a run loop. The runtime's
// thread is a dispatch queue without one, so `WebAssembly.compile()` and `instantiate()` would never settle. Their
// synchronous constructors work, so the promise APIs are rebuilt on them: compiling blocks the JavaScript thread
// instead of a background one, which only matters for large modules.
type WebAssemblyNamespace = {
	Module: new (bytes: BufferSource) => object;
	Instance: new (module: object, imports?: object) => object;
	compile?: unknown;
	instantiate?: unknown;
	compileStreaming?: unknown;
	instantiateStreaming?: unknown;
};

const wasm = (globalThis as { WebAssembly?: WebAssemblyNamespace }).WebAssembly;

if (wasm !== undefined) {
	const settle = <T>(body: () => T): Promise<T> =>
		new Promise((resolve, reject) => {
			try {
				resolve(body());
			} catch (error) {
				reject(error);
			}
		});
	const compile = (bytes: BufferSource) => settle(() => new wasm.Module(bytes));
	const instantiate = (source: BufferSource | object, imports?: object) =>
		settle(() => {
			if (source instanceof wasm.Module) return new wasm.Instance(source, imports);
			const module = new wasm.Module(source as BufferSource);
			return { module, instance: new wasm.Instance(module, imports) };
		});
	const bytesOf = async (response: Response | PromiseLike<Response>) => new Uint8Array(await (await response).arrayBuffer());
	wasm.compile = compile;
	wasm.instantiate = instantiate;
	wasm.compileStreaming = async (response: Response | PromiseLike<Response>) => compile(await bytesOf(response));
	wasm.instantiateStreaming = async (response: Response | PromiseLike<Response>, imports?: object) =>
		instantiate(await bytesOf(response), imports);
}
