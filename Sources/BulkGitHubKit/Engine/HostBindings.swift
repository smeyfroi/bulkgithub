import Foundation
import JavaScriptCore
import Yams

enum HostError: Error {
    case cancelled
    case invalidArgument(String)

    var message: String {
        switch self {
        case .cancelled: return "JobCancelled: the run was cancelled"
        case .invalidArgument(let m): return m
        }
    }
}

/// Simple counting semaphore for Swift concurrency; bounds concurrent host
/// calls so scripts can fan out naively with Promise.all.
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { self.available = max(1, count) }

    func wait() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
}

/// Builds the capability objects (`gh`, `job`, `parse`, `console`) injected
/// into a script context. The injected surface is the script's entire world:
/// a JSC context has no ambient filesystem, network, or process access.
///
/// Phase determines the capability set. Check phase installs the read-only
/// GitHub surface — write methods simply do not exist on the object.
enum HostBindings {

    static func install(in context: JSContext,
                        phase: JobPhase,
                        params: [String: String],
                        github: GitHubClient,
                        organisation: String,
                        collector: JobCollector,
                        limiter: AsyncSemaphore,
                        cancel: CancelBox,
                        vmQueue: DispatchQueue) {
        installGitHub(in: context, phase: phase, github: github, organisation: organisation,
                      collector: collector, limiter: limiter, cancel: cancel, vmQueue: vmQueue)
        installJob(in: context, params: params, collector: collector)
        installParse(in: context)
        installConsole(in: context, collector: collector)
    }

    // MARK: - gh

    private static func installGitHub(in context: JSContext, phase: JobPhase,
                                      github: GitHubClient, organisation: String,
                                      collector: JobCollector, limiter: AsyncSemaphore,
                                      cancel: CancelBox, vmQueue: DispatchQueue) {
        guard let gh = JSValue(newObjectIn: context) else { return }

        let listOrgRepos: @convention(block) () -> JSValue = {
            hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let repos = try await github.listOrgRepos(org: organisation)
                collector.registerCandidates(repos)
                collector.audit(kind: "gh.listOrgRepos", repo: nil, detail: "→ \(repos.count) repos")
                return repos.map(\.scriptValue)
            }
        }
        gh.setObject(unsafeBitCast(listOrgRepos, to: AnyObject.self),
                     forKeyedSubscript: "listOrgRepos" as NSString)

        let searchCode: @convention(block) (JSValue?) -> JSValue = { queryValue in
            guard let query = stringArg(queryValue) else {
                return rejectedPromise("searchCode: query string is required")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let repos = try await github.searchCode(org: organisation, query: query)
                collector.registerCandidates(repos)
                collector.audit(kind: "gh.searchCode", repo: nil,
                                detail: "\(query) → \(repos.count) candidate repos")
                return repos.map(\.scriptValue)
            }
        }
        gh.setObject(unsafeBitCast(searchCode, to: AnyObject.self),
                     forKeyedSubscript: "searchCode" as NSString)

        let getContent: @convention(block) (JSValue?, JSValue?, JSValue?) -> JSValue = { repoValue, pathValue, refValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("getContent: repo (object or \"owner/name\") is required")
            }
            guard let path = stringArg(pathValue) else {
                return rejectedPromise("getContent: path string is required")
            }
            let ref = stringArg(refValue)
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                do {
                    let content = try await github.getContent(repo: fullName, path: path, ref: ref)
                    if content != nil { collector.recordReceipt(repo: fullName, path: path) }
                    collector.audit(kind: "gh.getContent", repo: fullName,
                                    detail: path + (content == nil ? " (absent)" : " (\(content!.count) chars)"))
                    return content
                } catch {
                    // Failed fetches belong in the audit trail too.
                    collector.audit(kind: "gh.getContent", repo: fullName,
                                    detail: "\(path) failed: \(errorMessage(error))")
                    throw error
                }
            }
        }
        gh.setObject(unsafeBitCast(getContent, to: AnyObject.self),
                     forKeyedSubscript: "getContent" as NSString)

        let getRef: @convention(block) (JSValue?, JSValue?) -> JSValue = { repoValue, refValue in
            guard let fullName = repoName(repoValue), let ref = stringArg(refValue) else {
                return rejectedPromise("getRef: repo and ref are required")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let sha = try await github.getRef(repo: fullName, ref: ref)
                collector.audit(kind: "gh.getRef", repo: fullName, detail: "\(ref) → \(sha ?? "absent")")
                return sha.map { ["sha": $0] }
            }
        }
        gh.setObject(unsafeBitCast(getRef, to: AnyObject.self),
                     forKeyedSubscript: "getRef" as NSString)

        let listPRs: @convention(block) (JSValue?, JSValue?) -> JSValue = { repoValue, optsValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("listPRs: repo is required")
            }
            let head = stringArg(optsValue?.objectForKeyedSubscript("head"))
            let state = stringArg(optsValue?.objectForKeyedSubscript("state")) ?? "open"
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let prs = try await github.listPRs(repo: fullName, head: head, state: state)
                collector.audit(kind: "gh.listPRs", repo: fullName, detail: "→ \(prs.count) PRs")
                return prs.map(\.scriptValue)
            }
        }
        gh.setObject(unsafeBitCast(listPRs, to: AnyObject.self),
                     forKeyedSubscript: "listPRs" as NSString)

        let searchPRs: @convention(block) (JSValue?) -> JSValue = { queryValue in
            guard let query = stringArg(queryValue) else {
                return rejectedPromise("searchPRs: query string is required")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let prs = try await github.searchPRs(org: organisation, query: query)
                collector.audit(kind: "gh.searchPRs", repo: nil, detail: "\(query) → \(prs.count) PRs")
                return prs.map(\.scriptValue)
            }
        }
        gh.setObject(unsafeBitCast(searchPRs, to: AnyObject.self),
                     forKeyedSubscript: "searchPRs" as NSString)

        // Update/merge phases will install guarded write methods here (plan v2
        // phases 3-5). Until then the write surface does not exist at all.

        context.setObject(gh, forKeyedSubscript: "gh" as NSString)
    }

    // MARK: - job

    private static func installJob(in context: JSContext, params: [String: String],
                                   collector: JobCollector) {
        guard let job = JSValue(newObjectIn: context) else { return }

        let reportMatch: @convention(block) (JSValue?, JSValue?) -> Void = { repoValue, evidenceValue in
            guard let ctx = JSContext.current() else { return }
            guard let repoValue, let ref = resolveRepo(repoValue, collector: collector) else {
                ctx.exception = JSValue(newErrorFromMessage: "reportMatch: repo is required", in: ctx)
                return
            }
            guard let evidenceValue, evidenceValue.isObject,
                  let path = stringArg(evidenceValue.objectForKeyedSubscript("path")),
                  let excerpt = stringArg(evidenceValue.objectForKeyedSubscript("excerpt")) else {
                ctx.exception = JSValue(newErrorFromMessage:
                    "reportMatch: evidence { path, excerpt } is required", in: ctx)
                return
            }
            guard collector.hasReceipt(repo: ref.fullName, path: path) else {
                ctx.exception = JSValue(newErrorFromMessage:
                    "reportMatch: no fetched content for \(ref.fullName) \(path) — call gh.getContent first; search results are candidates, not proof",
                    in: ctx)
                return
            }
            let explanation = stringArg(evidenceValue.objectForKeyedSubscript("explanation"))
            let evidence = Evidence(path: path, excerpt: excerpt, explanation: explanation)
            collector.upsert(repo: ref, status: .verifiedMatch, reason: explanation, evidence: evidence)
            collector.audit(kind: "job.reportMatch", repo: ref.fullName, detail: path)
        }
        job.setObject(unsafeBitCast(reportMatch, to: AnyObject.self),
                      forKeyedSubscript: "reportMatch" as NSString)

        let skip: @convention(block) (JSValue?, JSValue?) -> Void = { repoValue, reasonValue in
            guard let repoValue, let ref = resolveRepo(repoValue, collector: collector) else { return }
            let reason = describe(reasonValue) ?? "skipped"
            collector.upsert(repo: ref, status: .skipped, reason: reason)
        }
        job.setObject(unsafeBitCast(skip, to: AnyObject.self), forKeyedSubscript: "skip" as NSString)

        let fail: @convention(block) (JSValue?, JSValue?) -> Void = { repoValue, messageValue in
            guard let repoValue, let ref = resolveRepo(repoValue, collector: collector) else { return }
            let message = describe(messageValue) ?? "error"
            collector.upsert(repo: ref, status: .failed, reason: message)
            collector.audit(kind: "job.error", repo: ref.fullName, detail: message)
        }
        job.setObject(unsafeBitCast(fail, to: AnyObject.self), forKeyedSubscript: "error" as NSString)

        let progress: @convention(block) (JSValue?) -> Void = { messageValue in
            collector.progress(describe(messageValue) ?? "")
        }
        job.setObject(unsafeBitCast(progress, to: AnyObject.self),
                      forKeyedSubscript: "progress" as NSString)

        let log: @convention(block) (JSValue?) -> Void = { messageValue in
            collector.log(describe(messageValue) ?? "")
        }
        job.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "log" as NSString)

        let writeState: @convention(block) (JSValue?, JSValue?) -> Void = { keyValue, value in
            guard let key = stringArg(keyValue) else { return }
            collector.writeState(key: key, value: value?.toObject() ?? NSNull())
        }
        job.setObject(unsafeBitCast(writeState, to: AnyObject.self),
                      forKeyedSubscript: "writeState" as NSString)

        let readState: @convention(block) (JSValue?) -> JSValue = { keyValue in
            let ctx = JSContext.current()!
            guard let key = stringArg(keyValue), let value = collector.readState(key: key) else {
                return JSValue(nullIn: ctx)
            }
            return JSValue(object: value, in: ctx)
        }
        job.setObject(unsafeBitCast(readState, to: AnyObject.self),
                      forKeyedSubscript: "readState" as NSString)

        job.setObject(params, forKeyedSubscript: "params" as NSString)

        context.setObject(job, forKeyedSubscript: "job" as NSString)
    }

    // MARK: - parse

    private static func installParse(in context: JSContext) {
        guard let parse = JSValue(newObjectIn: context) else { return }

        let yaml: @convention(block) (JSValue?) -> JSValue = { textValue in
            let ctx = JSContext.current()!
            guard let text = stringArg(textValue) else {
                ctx.exception = JSValue(newErrorFromMessage: "parse.yaml: text string is required", in: ctx)
                return JSValue(undefinedIn: ctx)
            }
            do {
                let object = try Yams.load(yaml: text)
                return JSValue(object: jsonSafe(object ?? NSNull()), in: ctx)
            } catch {
                ctx.exception = JSValue(newErrorFromMessage: "YAML parse error: \(error)", in: ctx)
                return JSValue(undefinedIn: ctx)
            }
        }
        parse.setObject(unsafeBitCast(yaml, to: AnyObject.self), forKeyedSubscript: "yaml" as NSString)

        let json: @convention(block) (JSValue?) -> JSValue = { textValue in
            let ctx = JSContext.current()!
            guard let text = stringArg(textValue), let data = text.data(using: .utf8) else {
                ctx.exception = JSValue(newErrorFromMessage: "parse.json: text string is required", in: ctx)
                return JSValue(undefinedIn: ctx)
            }
            do {
                let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                return JSValue(object: object, in: ctx)
            } catch {
                ctx.exception = JSValue(newErrorFromMessage: "JSON parse error: \(error.localizedDescription)", in: ctx)
                return JSValue(undefinedIn: ctx)
            }
        }
        parse.setObject(unsafeBitCast(json, to: AnyObject.self), forKeyedSubscript: "json" as NSString)

        let toml: @convention(block) (JSValue?) -> JSValue = { _ in
            let ctx = JSContext.current()!
            ctx.exception = JSValue(newErrorFromMessage:
                "parse.toml: TOML parsing is not yet supported by the host", in: ctx)
            return JSValue(undefinedIn: ctx)
        }
        parse.setObject(unsafeBitCast(toml, to: AnyObject.self), forKeyedSubscript: "toml" as NSString)

        context.setObject(parse, forKeyedSubscript: "parse" as NSString)
    }

    private static func installConsole(in context: JSContext, collector: JobCollector) {
        guard let console = JSValue(newObjectIn: context) else { return }
        let log: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            collector.log(args.map { $0.toString() ?? "" }.joined(separator: " "))
        }
        console.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "log" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    // MARK: - Helpers

    /// Wraps async Swift host work in a JS Promise.
    ///
    /// Threading contract: the detached task performs only Swift async work
    /// (network/fixture I/O). Settling the promise — which synchronously runs
    /// the script's continuation and drains JSC microtasks — is dispatched
    /// onto the run's dedicated serial vmQueue. JS never executes on the Swift
    /// cooperative pool (running it there starves the pool and deadlocks once
    /// enough host calls are in flight), and single-queue execution keeps the
    /// VM single-threaded.
    private static func hostPromise(limiter: AsyncSemaphore, cancel: CancelBox,
                                    vmQueue: DispatchQueue,
                                    work: @escaping @Sendable () async throws -> Any?) -> JSValue {
        let ctx = JSContext.current()!
        return JSValue(newPromiseIn: ctx) { resolve, reject in
            guard let resolve, let reject else { return }
            Task.detached {
                await limiter.wait()
                let settle: (JSValue, Any) -> Void = { fn, argument in
                    vmQueue.async { fn.call(withArguments: [argument]) }
                }
                do {
                    if cancel.isCancelled { throw HostError.cancelled }
                    let value = try await work()
                    await limiter.signal()
                    settle(resolve, value ?? NSNull())
                } catch {
                    await limiter.signal()
                    let message = errorMessage(error)
                    vmQueue.async {
                        if let context = reject.context,
                           let errorValue = JSValue(newErrorFromMessage: message, in: context) {
                            reject.call(withArguments: [errorValue])
                        } else {
                            reject.call(withArguments: [message])
                        }
                    }
                }
            }
        }
    }

    private static func rejectedPromise(_ message: String) -> JSValue {
        let ctx = JSContext.current()!
        return JSValue(newPromiseIn: ctx) { _, reject in
            reject?.call(withArguments: [JSValue(newErrorFromMessage: message, in: ctx) ?? message])
        }
    }

    static func errorMessage(_ error: Error) -> String {
        if let host = error as? HostError { return host.message }
        if error is CancellationError { return HostError.cancelled.message }
        if let gh = error as? GitHubClientError { return gh.errorDescription ?? String(describing: gh) }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    static func stringArg(_ value: JSValue?) -> String? {
        guard let value, value.isString else { return nil }
        return value.toString()
    }

    static func describe(_ value: JSValue?) -> String? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        return value.toString()
    }

    /// Accepts either "owner/name" or a Repo object from a prior gh call.
    static func repoName(_ value: JSValue?) -> String? {
        guard let value else { return nil }
        if value.isString {
            let s = value.toString() ?? ""
            return s.isEmpty ? nil : s
        }
        if value.isObject, let nameValue = value.objectForKeyedSubscript("fullName"),
           nameValue.isString {
            let s = nameValue.toString() ?? ""
            return s.isEmpty ? nil : s
        }
        return nil
    }

    static func resolveRepo(_ value: JSValue, collector: JobCollector) -> RepoRef? {
        guard let fullName = repoName(value) else { return nil }
        if value.isObject {
            var ref = collector.repo(named: fullName)
            if let branch = stringArg(value.objectForKeyedSubscript("defaultBranch")) {
                ref.defaultBranch = branch
            }
            if let archived = value.objectForKeyedSubscript("archived"), archived.isBoolean {
                ref.archived = archived.toBool()
            }
            return ref
        }
        return collector.repo(named: fullName)
    }

    /// Yams can produce dictionaries with non-string keys; make everything
    /// JS-bridgeable before handing it to JSValue(object:in:).
    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dict as [AnyHashable: Any]:
            var out = [String: Any]()
            for (key, inner) in dict { out[String(describing: key.base)] = jsonSafe(inner) }
            return out
        case let array as [Any]:
            return array.map(jsonSafe)
        case is NSNull, is String, is Int, is Double, is Bool, is NSNumber:
            return value
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        default:
            return String(describing: value)
        }
    }
}
