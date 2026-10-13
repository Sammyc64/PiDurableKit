import CryptoKit
import Foundation
import JavaScriptCore
import os

/// Runs code mode's QuickJS VMs off the runtime's JavaScript thread: each execution gets a worker, a JavaScriptCore
/// context of its own on its own queue, running `codemode-worker.js` (the remote side of pi-codemode's
/// `RemoteCodemodeSandbox`). A script that computes then holds up only its own worker, not the runtime's other work,
/// such as streaming replies in other conversations.
///
/// The runtime keeps the tools, the deadline, and the abort; every exchange of messages between the VM and the runtime
/// crosses through here. Idle workers are kept for the next execution, which then skips compiling QuickJS.
final class CodemodeWorkers: Sendable {
    /// Idle workers kept for later executions.
    static let keptIdle = 2

    private let idle = OSAllocatedUnfairLock<[CodemodeWorker]>(initialState: [])
    private let log: @Sendable (Runtime.LogLevel, String) -> Void

    init(log: @escaping @Sendable (Runtime.LogLevel, String) -> Void) {
        self.log = log
    }

    /// Runs one execution in a worker; returns once it has ended. `exchange` passes a JSON array of the worker's
    /// messages to the runtime and returns the runtime's JSON reply.
    func execute(
        request: String, wasmPath: String, exchange: @escaping @Sendable (String) async throws -> String
    ) async throws {
        let worker: CodemodeWorker
        if let kept = idle.withLock({ $0.popLast() }) { worker = kept } else { worker = try CodemodeWorker(log: log) }
        await worker.serve(request: request, wasmPath: wasmPath, exchange: exchange)
        idle.withLock { workers in
            if workers.count < Self.keptIdle { workers.append(worker) }
        }
    }
}

/// One worker: a JavaScriptCore context confined to its own serial queue, serving one execution at a time.
final class CodemodeWorker: @unchecked Sendable {
    private let queue = DispatchSerialQueue(label: "PiDurableKit.Codemode", qos: .userInitiated)
    private let log: @Sendable (Runtime.LogLevel, String) -> Void

    // On `queue`.
    private var context: JSContext!
    private var worker: JSValue!
    private var runtime: JSValue!
    private var timers: [Int: DispatchWorkItem] = [:]
    private var exchange: (@Sendable (String) async throws -> String)?
    private var finished: CheckedContinuation<Void, Never>?

    init(log: @escaping @Sendable (Runtime.LogLevel, String) -> Void) throws {
        self.log = log
        try queue.sync { try load() }
    }

    func serve(request: String, wasmPath: String, exchange: @escaping @Sendable (String) async throws -> String) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.exchange = exchange
                self.finished = continuation
                self.worker.invokeMethod("serve", withArguments: [request, wasmPath])
                self.reportException()
            }
        }
    }

    // MARK: Loading

    private func load() throws {
        guard let url = Bundle.module.url(forResource: "codemode-worker", withExtension: "js") else {
            throw PiDurableError.runtime("The code mode worker is missing from the PiDurableKit resources")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let context = JSContext() else { throw PiDurableError.runtime("Could not create a JavaScript context") }
        context.name = "PiDurableKit code mode"
        self.context = context
        installNatives(in: context)
        context.evaluateScript(source, withSourceURL: url)
        if let exception = context.exception {
            throw PiDurableError.runtime("Loading the code mode worker failed: \(Engine.describe(exception))")
        }
        worker = context.objectForKeyedSubscript("__worker")
        runtime = context.objectForKeyedSubscript("__runtime")
    }

    private func reportException() {
        guard let exception = context.exception else { return }
        context.exception = nil
        log(.error, "Uncaught JavaScript exception in code mode: \(Engine.describe(exception))")
    }

    // MARK: Natives

    private func installNatives(in context: JSContext) {
        let native = JSValue(newObjectIn: context)!
        func define(_ name: String, _ block: Any) {
            native.setObject(block, forKeyedSubscript: name as NSString)
        }

        define("log", { [log] (level: String, message: String) in
            log(Runtime.LogLevel(rawValue: level) ?? .info, message)
        } as @convention(block) (String, String) -> Void)

        define("now", { Date().timeIntervalSince1970 * 1000 } as @convention(block) () -> Double)

        define("setTimer", { [unowned self] (id: Int, delay: Double) in
            self.timers[id]?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.timers.removeValue(forKey: id) != nil else { return }
                self.runtime.invokeMethod("fireTimer", withArguments: [id])
                self.reportException()
            }
            self.timers[id] = item
            self.queue.asyncAfter(deadline: .now() + .milliseconds(Int(Engine.timerDelay(delay))), execute: item)
        } as @convention(block) (Int, Double) -> Void)

        define("clearTimer", { [unowned self] (id: Int) in
            self.timers.removeValue(forKey: id)?.cancel()
        } as @convention(block) (Int) -> Void)

        define("randomBytes", { (array: JSValue) in
            guard let buffer = TypedArray.bytes(of: array) else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        } as @convention(block) (JSValue) -> Void)

        define("sha256", { (bytes: JSValue) -> JSValue in
            let context = JSContext.current()!
            let digest = Data(SHA256.hash(data: TypedArray.data(of: bytes) ?? Data()))
            return TypedArray.makeUint8Array(digest, in: context) ?? JSValue(undefinedIn: context)
        } as @convention(block) (JSValue) -> JSValue)

        define("fsReadFile", { (path: String) -> JSValue in
            let context = JSContext.current()!
            do {
                return TypedArray.makeUint8Array(try FileOperations.read(path), in: context) ?? JSValue(undefinedIn: context)
            } catch {
                Engine.throwJavaScriptError(error)
                return JSValue(undefinedIn: context)
            }
        } as @convention(block) (String) -> JSValue)

        // One exchange: the runtime answers on its own thread, and the reply comes back to this queue. A runtime that
        // can't be reached stops the execution.
        define("exchange", { [unowned self] (id: Int, messages: String) in
            guard let exchange = self.exchange else { return }
            Task {
                let reply = (try? await exchange(messages)) ?? #"{"type":"stop"}"#
                self.queue.async {
                    self.worker.invokeMethod("reply", withArguments: [id, reply])
                    self.reportException()
                }
            }
        } as @convention(block) (Int, String) -> Void)

        define("done", { [unowned self] in
            self.exchange = nil
            let finished = self.finished
            self.finished = nil
            finished?.resume()
        } as @convention(block) () -> Void)

        context.setObject(native, forKeyedSubscript: "__native" as NSString)
    }
}
