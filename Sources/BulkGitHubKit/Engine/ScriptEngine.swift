import Foundation
import JavaScriptCore

public struct EngineConfiguration: Sendable {
    /// Longest uninterrupted synchronous JS slice before the watchdog fires.
    public var maxSyncSliceSeconds: Double = 2.0
    /// Total synchronous JS execution budget for a run (await time excluded).
    public var maxSyncBudgetSeconds: Double = 60.0
    /// Wall-clock ceiling for the whole run.
    public var maxRunSeconds: Double = 900
    /// Concurrent host (GitHub) calls; scripts may Promise.all freely.
    public var maxConcurrentHostCalls: Int = 8
    /// Canary targeting: when set, repo enumeration (listOrgRepos/searchCode)
    /// only returns these repos, and recorded write actions for any other
    /// repo are dropped (marked "outside canary target") — so an update can
    /// be trialled against a single repository first.
    public var targetRepos: Set<String>?

    public init() {}

    public init(settings: AppSettings) {
        self.maxSyncSliceSeconds = settings.syncSliceSeconds
        self.maxSyncBudgetSeconds = settings.maxSyncBudgetSeconds
        self.maxRunSeconds = settings.maxRunSeconds
        self.maxConcurrentHostCalls = settings.maxConcurrentOps
    }
}

/// Executes a validated (already-transpiled) script in a fresh JavaScriptCore
/// context wired to the capability handles for the given phase.
///
/// The context has no ambient capabilities: no filesystem, network, process,
/// or timers. Everything the script can do goes through the injected handles,
/// which audit every effectful call. Credentials never enter the context.
public final class ScriptEngine {

    public init() {}

    private static let runnerShim = """
    globalThis.__bgh_run = async () => {
      if (typeof main !== "function") {
        throw new Error("script must define async function main()");
      }
      return main();
    };
    """

    public func run(javaScript: String,
                    phase: JobPhase,
                    params: [String: String],
                    github: GitHubClient,
                    organisation: String,
                    configuration: EngineConfiguration = EngineConfiguration(),
                    initialState: [String: String] = [:],
                    onEvent: @escaping (RunEvent) -> Void) async -> RunOutcome {
        let start = Date()
        let collector = JobCollector(initialState: initialState,
                                     targetRepos: configuration.targetRepos,
                                     onEvent: onEvent)
        let cancel = CancelBox()
        let limiter = AsyncSemaphore(configuration.maxConcurrentHostCalls)

        func outcome(_ status: RunStatus) -> RunOutcome {
            RunOutcome(status: status,
                       results: collector.snapshotResults,
                       logs: collector.snapshotLogs,
                       auditEvents: collector.snapshotAudit,
                       plannedActions: collector.snapshotPlan,
                       state: collector.snapshotState,
                       duration: Date().timeIntervalSince(start))
        }

        guard let vm = JSVirtualMachine(), let context = JSContext(virtualMachine: vm) else {
            return outcome(.failed("could not create JavaScript context"))
        }
        context.name = "BulkGitHub script"

        let exceptions = ExceptionBox()
        context.exceptionHandler = { _, exception in
            exceptions.record(exception?.toString() ?? "unknown exception")
        }

        // Watchdog: bounds synchronous JS slices; also the hard-stop for
        // cancellation when a script never yields back to the host.
        let watchdog = WatchdogState(cancel: cancel,
                                     slice: configuration.maxSyncSliceSeconds,
                                     budget: configuration.maxSyncBudgetSeconds)
        let group = JSContextGetGroup(context.jsGlobalContextRef)
        watchdog.group = group
        let watchdogRef = Unmanaged.passRetained(watchdog)
        let watchdogInstalled = JSCWatchdogAPI.setLimit(group: group,
                                                        seconds: configuration.maxSyncSliceSeconds,
                                                        info: watchdogRef.toOpaque())
        if !watchdogInstalled {
            collector.log("note: JSC execution watchdog unavailable on this system")
        }
        defer {
            if watchdogInstalled { JSCWatchdogAPI.clearLimit(group: group) }
            watchdogRef.release()
        }

        // All JSC execution for this run is confined to one serial GCD queue:
        // loading the script, invoking main(), and every microtask drain
        // triggered by a settling host promise. JS must never run on the Swift
        // cooperative pool — synchronous JS continuations would pin pool
        // threads and deadlock the pool once enough host calls are in flight.
        let vmQueue = DispatchQueue(label: "me.geo.bulkgithub.vm")

        HostBindings.install(in: context, phase: phase, params: params,
                             github: github, organisation: organisation,
                             collector: collector, limiter: limiter, cancel: cancel,
                             vmQueue: vmQueue)

        collector.log("run started (phase: \(phase.rawValue), org: \(organisation))")

        let once = SettleOnce()
        let earlyFailure: String? = await withCheckedContinuation { continuation in
            vmQueue.async {
                context.evaluateScript(javaScript)
                if let message = exceptions.take() {
                    continuation.resume(returning: "script failed to load: \(message)")
                    return
                }
                context.evaluateScript(Self.runnerShim)
                guard let runner = context.objectForKeyedSubscript("__bgh_run"),
                      let promise = runner.call(withArguments: []) else {
                    continuation.resume(returning: "could not invoke main()")
                    return
                }
                if let message = exceptions.take() {
                    continuation.resume(returning: message)
                    return
                }
                guard promise.isObject else {
                    continuation.resume(returning: "main() did not produce a promise")
                    return
                }

                let onFulfilled: @convention(block) (JSValue?) -> Void = { _ in
                    once.resume(.completed)
                }
                let onRejected: @convention(block) (JSValue?) -> Void = { error in
                    let message = error?.toString() ?? "script failed"
                    if message.contains("JobCancelled") {
                        once.resume(.cancelled)
                    } else {
                        once.resume(.failed(message))
                    }
                }
                promise.invokeMethod("then", withArguments: [
                    unsafeBitCast(onFulfilled, to: AnyObject.self),
                    unsafeBitCast(onRejected, to: AnyObject.self),
                ])
                continuation.resume(returning: nil)
            }
        }
        if let earlyFailure {
            collector.log(earlyFailure)
            return outcome(.failed(earlyFailure))
        }

        let status = await Self.awaitSettlement(once: once, cancel: cancel,
                                                maxRunSeconds: configuration.maxRunSeconds)
        if status == .completed { collector.finalizeUnreportedCandidates() }
        collector.log("run \(status.label) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        return outcome(status)
    }

    // MARK: - Settlement

    private static func awaitSettlement(once: SettleOnce,
                                        cancel: CancelBox,
                                        maxRunSeconds: Double) async -> RunStatus {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<RunStatus, Never>) in
                let timeout = Task.detached {
                    try? await Task.sleep(for: .seconds(maxRunSeconds))
                    guard !Task.isCancelled else { return }
                    cancel.cancel()
                    once.resume(.failed("run exceeded \(Int(maxRunSeconds))s wall-clock limit"))
                }
                once.onResume = { timeout.cancel() }
                // The script may already have settled while handlers were
                // being armed on the VM queue — arm() replays a buffered
                // settlement immediately.
                once.arm(continuation)
            }
        } onCancel: {
            cancel.cancel()
            // Give pending host calls a moment to reject and the script to
            // settle naturally; then force the outcome.
            Task.detached {
                try? await Task.sleep(for: .seconds(2))
                once.resume(.cancelled)
            }
        }
    }
}

// MARK: - JSC watchdog (private C API, bound dynamically)

/// JSContextGroupSetExecutionTimeLimit / Clear are declared in JavaScriptCore's
/// private headers but exported from the framework (verified in the SDK tbd,
/// stable for many releases). Bound via dlsym so a future removal degrades to
/// "no watchdog" instead of a link failure. Fine for Developer ID distribution.
enum JSCWatchdogAPI {
    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimitFn = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void
    private typealias ClearLimitFn = @convention(c) (JSContextGroupRef?) -> Void

    private static let setLimitFn: SetLimitFn? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "JSContextGroupSetExecutionTimeLimit") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetLimitFn.self)
    }()

    private static let clearLimitFn: ClearLimitFn? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "JSContextGroupClearExecutionTimeLimit") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ClearLimitFn.self)
    }()

    private static let callback: ShouldTerminate = { _, info in
        guard let info else { return false }
        let state = Unmanaged<WatchdogState>.fromOpaque(info).takeUnretainedValue()
        if state.sliceElapsed() { return true }
        // Returning false does NOT restart the timer (verified empirically on
        // macOS 26 — a single fire, then never again). The callback must
        // re-arm itself for the next slice.
        if let group = state.group {
            setLimitFn?(group, state.slice, callback, info)
        }
        return false
    }

    /// Returns false when the symbol is unavailable.
    @discardableResult
    static func setLimit(group: JSContextGroupRef?, seconds: Double,
                         info: UnsafeMutableRawPointer) -> Bool {
        guard let setLimitFn else { return false }
        setLimitFn(group, seconds, callback, info)
        return true
    }

    static func clearLimit(group: JSContextGroupRef?) {
        clearLimitFn?(group)
    }
}

// MARK: - Support types

final class ExceptionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var last: String?

    func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        last = message
    }

    func take() -> String? {
        lock.lock(); defer { lock.unlock() }
        let value = last
        last = nil
        return value
    }
}

final class WatchdogState: @unchecked Sendable {
    private let lock = NSLock()
    private var budgetRemaining: Double
    let slice: Double
    private let cancel: CancelBox
    /// Set once before arming; read from the JS thread by the re-arming
    /// callback. Valid for the run's lifetime (the engine retains the VM).
    var group: JSContextGroupRef?

    init(cancel: CancelBox, slice: Double, budget: Double) {
        self.cancel = cancel
        self.slice = slice
        self.budgetRemaining = budget
    }

    /// Called from the JSC watchdog each time a synchronous slice elapses.
    /// Returning true terminates execution.
    func sliceElapsed() -> Bool {
        if cancel.isCancelled { return true }
        lock.lock(); defer { lock.unlock() }
        budgetRemaining -= slice
        return budgetRemaining <= 0
    }
}

/// Resolves a run's settlement exactly once, tolerating either order of
/// "continuation armed" and "settlement arrived" (a synchronously-failing
/// script settles on the VM queue before the awaiting side has armed).
final class SettleOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RunStatus, Never>?
    private var pending: RunStatus?
    private var resumed = false
    var onResume: (() -> Void)?

    func arm(_ continuation: CheckedContinuation<RunStatus, Never>) {
        lock.lock()
        if let pending, !resumed {
            resumed = true
            let cleanup = onResume
            onResume = nil
            lock.unlock()
            continuation.resume(returning: pending)
            cleanup?()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ status: RunStatus) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        guard let continuation else {
            if pending == nil { pending = status }
            lock.unlock()
            return
        }
        resumed = true
        self.continuation = nil
        let cleanup = onResume
        onResume = nil
        lock.unlock()
        continuation.resume(returning: status)
        cleanup?()
    }
}
