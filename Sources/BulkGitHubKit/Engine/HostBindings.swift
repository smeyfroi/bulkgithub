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
                        vmQueue: DispatchQueue,
                        writeMode: EngineConfiguration.WriteMode = .dryRun,
                        prTitleOverride: String? = nil,
                        prBodyOverride: String? = nil) {
        installGitHub(in: context, phase: phase, github: github, organisation: organisation,
                      collector: collector, limiter: limiter, cancel: cancel, vmQueue: vmQueue,
                      writeMode: writeMode,
                      prTitleOverride: prTitleOverride, prBodyOverride: prBodyOverride)
        installJob(in: context, params: params, collector: collector)
        installParse(in: context)
        installConsole(in: context, collector: collector)
    }

    // MARK: - gh

    private static func installGitHub(in context: JSContext, phase: JobPhase,
                                      github: GitHubClient, organisation: String,
                                      collector: JobCollector, limiter: AsyncSemaphore,
                                      cancel: CancelBox, vmQueue: DispatchQueue,
                                      writeMode: EngineConfiguration.WriteMode = .dryRun,
                                      prTitleOverride: String? = nil,
                                      prBodyOverride: String? = nil) {
        guard let gh = JSValue(newObjectIn: context) else { return }

        let listOrgRepos: @convention(block) () -> JSValue = {
            hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let all = try await github.listOrgRepos(org: organisation)
                let repos = all.filter { !collector.isOutsideCanary($0.fullName) }
                collector.registerCandidates(repos)
                let detail = repos.count == all.count
                    ? "→ \(repos.count) repos"
                    : "→ \(repos.count) of \(all.count) repos (scoped)"
                collector.audit(kind: "gh.listOrgRepos", repo: nil, detail: detail)
                return repos.map(\.scriptValue)
            }
        }
        gh.setObject(unsafeBitCast(listOrgRepos, to: AnyObject.self),
                     forKeyedSubscript: "listOrgRepos" as NSString)

        let getRepo: @convention(block) (JSValue?) -> JSValue = { repoValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("getRepo: repo (object or \"owner/name\") is required")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let repo = try await github.getRepo(fullName: fullName)
                collector.remember(repo)
                collector.audit(kind: "gh.getRepo", repo: fullName,
                                detail: "default branch \(repo.defaultBranch)")
                return repo.scriptValue
            }
        }
        gh.setObject(unsafeBitCast(getRepo, to: AnyObject.self),
                     forKeyedSubscript: "getRepo" as NSString)

        let searchCode: @convention(block) (JSValue?) -> JSValue = { queryValue in
            guard let query = stringArg(queryValue) else {
                return rejectedPromise("searchCode: query string is required")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let all = try await github.searchCode(org: organisation, query: query)
                let repos = all.filter { !collector.isOutsideCanary($0.fullName) }
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
                    if let content {
                        collector.recordReceipt(repo: fullName, path: path, content: content)
                    }
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

        let listFiles: @convention(block) (JSValue?, JSValue?, JSValue?) -> JSValue = { repoValue, globValue, refValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("listFiles: repo (object or \"owner/name\") is required")
            }
            let glob = stringArg(globValue)
            let ref = stringArg(refValue)
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let all = try await github.listFiles(repo: fullName, ref: ref)
                let paths = glob.map { GlobMatcher.filter(all, glob: $0) } ?? all
                collector.audit(kind: "gh.listFiles", repo: fullName,
                                detail: "\(glob ?? "(all)") → \(paths.count) of \(all.count) files")
                return paths
            }
        }
        gh.setObject(unsafeBitCast(listFiles, to: AnyObject.self),
                     forKeyedSubscript: "listFiles" as NSString)

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

        // Custom-property reads — present on EVERY handle (check included). The
        // org bulk read is the authoritative query backbone; reading a repo's
        // properties earns a property receipt that lets job.reportMatch accept a
        // property-based match (authoritative data, not a stale search index).
        let listOrgProperties: @convention(block) () -> JSValue = {
            hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let all = try await github.listOrgProperties(org: organisation)
                let scoped = all.filter { !collector.isOutsideCanary($0.repo.fullName) }
                collector.registerCandidates(scoped.map(\.repo))
                for entry in scoped {
                    collector.recordPropertyReceipt(repo: entry.repo.fullName, values: entry.properties)
                }
                collector.audit(kind: "gh.listOrgProperties", repo: nil,
                                detail: "→ \(scoped.count) repo(s) with custom properties")
                return scoped.map { entry -> [String: Any] in
                    ["repo": entry.repo.scriptValue,
                     "properties": entry.properties.mapValues { $0.scriptValue }]
                }
            }
        }
        gh.setObject(unsafeBitCast(listOrgProperties, to: AnyObject.self),
                     forKeyedSubscript: "listOrgProperties" as NSString)

        let getProperties: @convention(block) (JSValue?) -> JSValue = { repoValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("getProperties: repo (object or \"owner/name\") is required")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let props = try await github.getProperties(repo: fullName)
                collector.recordPropertyReceipt(repo: fullName, values: props)
                collector.audit(kind: "gh.getProperties", repo: fullName,
                                detail: "→ \(props.count) propert\(props.count == 1 ? "y" : "ies")")
                return props.mapValues { $0.scriptValue }
            }
        }
        gh.setObject(unsafeBitCast(getProperties, to: AnyObject.self),
                     forKeyedSubscript: "getProperties" as NSString)

        let listPropertyDefs: @convention(block) () -> JSValue = {
            hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let defs = try await github.listPropertyDefs(org: organisation)
                collector.cachePropertyDefs(defs)
                collector.audit(kind: "gh.listPropertyDefs", repo: nil,
                                detail: "→ \(defs.count) definition(s)")
                return defs.map(\.scriptValue)
            }
        }
        gh.setObject(unsafeBitCast(listPropertyDefs, to: AnyObject.self),
                     forKeyedSubscript: "listPropertyDefs" as NSString)

        // Update phase write surface. The script-facing API is IDENTICAL in
        // both modes — the same reviewed script re-runs unchanged:
        // - dry run (default): writes are recorded as PlannedActions and
        //   answered with synthesized responses; nothing reaches the client.
        // - armed: writes call the GitHub client, guarded by repo selection,
        //   conformance with the reviewed plan, the drift guard, and
        //   idempotency checks.
        // Check-phase contexts never get these properties at all.
        if phase == .update {
            switch writeMode {
            case .dryRun:
                installRecordingWrites(on: gh, collector: collector,
                                       limiter: limiter, cancel: cancel, vmQueue: vmQueue,
                                       prTitleOverride: prTitleOverride, prBodyOverride: prBodyOverride)
            case .armed:
                installArmedWrites(on: gh, github: github, organisation: organisation,
                                   collector: collector,
                                   limiter: limiter, cancel: cancel, vmQueue: vmQueue,
                                   prTitleOverride: prTitleOverride, prBodyOverride: prBodyOverride)
            }
        }

        // Merge phase: the registry-scoped merge surface. Same dry-run /
        // armed split as updates — the same reviewed script re-runs armed.
        if phase == .merge {
            installMergeSurface(on: gh, github: github, collector: collector,
                                limiter: limiter, cancel: cancel, vmQueue: vmQueue,
                                armed: writeMode == .armed)
        }

        context.setObject(gh, forKeyedSubscript: "gh" as NSString)
    }

    private static func installRecordingWrites(on gh: JSValue, collector: JobCollector,
                                               limiter: AsyncSemaphore, cancel: CancelBox,
                                               vmQueue: DispatchQueue,
                                               prTitleOverride: String? = nil,
                                               prBodyOverride: String? = nil) {
        let createBranch: @convention(block) (JSValue?, JSValue?, JSValue?) -> JSValue = { repoValue, nameValue, shaValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("createBranch: repo is required")
            }
            guard let name = stringArg(nameValue), let sha = stringArg(shaValue) else {
                return rejectedPromise("createBranch: name and fromSha are required")
            }
            guard name.hasPrefix("bulkgh/") else {
                return rejectedPromise(
                    "createBranch: branch names must start with \"bulkgh/\" — job-prefixed branches are the only ones this app will ever create or delete (host rule)")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                collector.recordAction(repo: fullName, .createBranch(name: name, fromSha: sha))
                collector.audit(kind: "plan.createBranch", repo: fullName,
                                detail: "\(name) from \(String(sha.prefix(12))) (dry-run)")
                return ["sha": syntheticSha("\(fullName)#\(name)")]
            }
        }
        gh.setObject(unsafeBitCast(createBranch, to: AnyObject.self),
                     forKeyedSubscript: "createBranch" as NSString)

        let putContent: @convention(block) (JSValue?, JSValue?, JSValue?, JSValue?) -> JSValue = { repoValue, pathValue, contentValue, optsValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("putContent: repo is required")
            }
            guard let path = stringArg(pathValue), let content = stringArg(contentValue) else {
                return rejectedPromise("putContent: path and content are required")
            }
            guard let opts = optsValue, opts.isObject,
                  let branch = stringArg(opts.objectForKeyedSubscript("branch")),
                  let message = stringArg(opts.objectForKeyedSubscript("message")) else {
                return rejectedPromise("putContent: opts { branch, message } are required")
            }
            guard branch.hasPrefix("bulkgh/") else {
                return rejectedPromise("putContent: writes are only allowed on \"bulkgh/\"-prefixed branches (host rule)")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let before = collector.fetchedContent(repo: fullName, path: path)
                collector.recordAction(repo: fullName, .putContent(path: path, branch: branch,
                                                                   message: message,
                                                                   before: before, after: content))
                collector.audit(kind: "plan.putContent", repo: fullName,
                                detail: "\(path) on \(branch) (\(content.count) chars, dry-run)")
                return nil
            }
        }
        gh.setObject(unsafeBitCast(putContent, to: AnyObject.self),
                     forKeyedSubscript: "putContent" as NSString)

        let deleteContent: @convention(block) (JSValue?, JSValue?, JSValue?) -> JSValue = { repoValue, pathValue, optsValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("deleteContent: repo is required")
            }
            guard let path = stringArg(pathValue) else {
                return rejectedPromise("deleteContent: path is required")
            }
            guard let opts = optsValue, opts.isObject,
                  let branch = stringArg(opts.objectForKeyedSubscript("branch")),
                  let message = stringArg(opts.objectForKeyedSubscript("message")) else {
                return rejectedPromise("deleteContent: opts { branch, message } are required")
            }
            guard branch.hasPrefix("bulkgh/") else {
                return rejectedPromise("deleteContent: writes are only allowed on \"bulkgh/\"-prefixed branches (host rule)")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let before = collector.fetchedContent(repo: fullName, path: path)
                collector.recordAction(repo: fullName, .deleteFile(path: path, branch: branch,
                                                                   message: message, before: before))
                collector.audit(kind: "plan.deleteContent", repo: fullName,
                                detail: "\(path) on \(branch) (dry-run)")
                return nil
            }
        }
        gh.setObject(unsafeBitCast(deleteContent, to: AnyObject.self),
                     forKeyedSubscript: "deleteContent" as NSString)

        let createPR: @convention(block) (JSValue?, JSValue?) -> JSValue = { repoValue, optsValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("createPR: repo is required")
            }
            guard let opts = optsValue, opts.isObject,
                  let head = stringArg(opts.objectForKeyedSubscript("head")),
                  let rawTitle = stringArg(opts.objectForKeyedSubscript("title")),
                  let rawBody = stringArg(opts.objectForKeyedSubscript("body")) else {
                return rejectedPromise("createPR: opts { head, title, body } are required")
            }
            // Host-authoritative PR title/body: the user's reviewed fields win
            // over whatever the script passed, when set.
            let title = (prTitleOverride?.isEmpty == false) ? prTitleOverride! : rawTitle
            let body = (prBodyOverride?.isEmpty == false) ? prBodyOverride! : rawBody
            guard head.hasPrefix("bulkgh/") else {
                return rejectedPromise("createPR: head must be a \"bulkgh/\"-prefixed branch (host rule)")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                collector.recordAction(repo: fullName, .createPR(headRef: head, title: title, body: body))
                collector.audit(kind: "plan.createPR", repo: fullName,
                                detail: "\"\(title)\" from \(head) (dry-run)")
                return PullRequestRef(repo: fullName, number: 0, headRef: head,
                                      headSha: syntheticSha("\(fullName)#\(head)"),
                                      state: "open", url: "(dry-run)").scriptValue
            }
        }
        gh.setObject(unsafeBitCast(createPR, to: AnyObject.self),
                     forKeyedSubscript: "createPR" as NSString)

        // Custom-property write (dry-run): validate against the org schema at
        // review time, then record the per-key before→after as a planned action.
        let setProperties: @convention(block) (JSValue?, JSValue?) -> JSValue = { repoValue, valuesValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("setProperties: repo is required")
            }
            guard let desired = parsePropertyValues(valuesValue), !desired.isEmpty else {
                return rejectedPromise("setProperties: a non-empty values object { name: value } is required")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                if collector.isOutsideCanary(fullName) {
                    collector.recordAction(repo: fullName, .setProperties(values: desired, before: [:]))
                    return nil
                }
                // Dry run is PURE RECORDING — it makes no host-initiated GitHub
                // calls, exactly like the file-write recording handle. The only
                // live reads during a dry run are the script's own (e.g.
                // gh.getProperties for the diff). Allowed-values are validated
                // here only when the script already fetched the schema
                // (gh.listPropertyDefs, cached); otherwise the armed run enforces
                // them before any write. Nothing here reaches GitHub.
                if let defs = collector.cachedPropertyDefs(),
                   let problem = validateValues(desired, against: defs) {
                    collector.upsert(repo: collector.repo(named: fullName), status: .failed, reason: problem)
                    collector.audit(kind: "plan.setProperties", repo: fullName, detail: "rejected: \(problem)")
                    return nil
                }
                let before = subset(collector.fetchedPropertyValues(repo: fullName), keys: Array(desired.keys))
                collector.recordAction(repo: fullName, .setProperties(values: desired, before: before))
                collector.audit(kind: "plan.setProperties", repo: fullName,
                                detail: "\(desired.count) propert\(desired.count == 1 ? "y" : "ies") (dry-run)")
                return nil
            }
        }
        gh.setObject(unsafeBitCast(setProperties, to: AnyObject.self),
                     forKeyedSubscript: "setProperties" as NSString)
    }

    // MARK: - Armed writes (guarded live handle)

    /// The guarded write surface for ARMED runs. Same script-facing API as
    /// the recording surface, but writes reach the GitHub client — after
    /// passing, in order:
    /// 1. repo selection (only repos the user armed),
    /// 2. halt state (a repo that conflicted/halted writes nothing further),
    /// 3. plan conformance (the call must be exactly the next action of the
    ///    reviewed dry-run plan),
    /// 4. drift guard (putContent: the remote file must still match the
    ///    plan's recorded "before", and the script's output must match the
    ///    reviewed "after"),
    /// 5. idempotency with registry-gated RESUME: an existing branch/PR that
    ///    THIS job created (it holds the artifact receipt) is continued on —
    ///    already-applied steps are skipped, missing ones executed; anything
    ///    with the same name the job did NOT create halts the repo.
    /// "What you reviewed is exactly what gets written, or nothing."
    private static func installArmedWrites(on gh: JSValue, github: GitHubClient,
                                           organisation: String,
                                           collector: JobCollector,
                                           limiter: AsyncSemaphore, cancel: CancelBox,
                                           vmQueue: DispatchQueue,
                                           prTitleOverride: String? = nil,
                                           prBodyOverride: String? = nil) {
        @Sendable func preflight(_ repo: String) throws {
            if collector.isOutsideCanary(repo) {
                collector.haltRepo(repo, status: .skipped,
                                   reason: "not selected for writes — nothing written")
                throw GitHubClientError.http(403, "\(repo) is not selected for this armed run")
            }
            if collector.isHalted(repo) {
                throw GitHubClientError.http(409, "writes to \(repo) were halted earlier in this run")
            }
        }

        let createBranch: @convention(block) (JSValue?, JSValue?, JSValue?) -> JSValue = { repoValue, nameValue, shaValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("createBranch: repo is required")
            }
            guard let name = stringArg(nameValue), let sha = stringArg(shaValue) else {
                return rejectedPromise("createBranch: name and fromSha are required")
            }
            guard name.hasPrefix("bulkgh/") else {
                return rejectedPromise(
                    "createBranch: branch names must start with \"bulkgh/\" — job-prefixed branches are the only ones this app will ever create or delete (host rule)")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                try preflight(fullName)
                guard case .createBranch(let expectedName, _)? = collector.expectedNextAction(repo: fullName),
                      expectedName == name else {
                    collector.haltRepo(fullName, status: .conflicted,
                                       reason: "script deviated from the reviewed plan (createBranch \(name)) — nothing written")
                    throw GitHubClientError.http(409, "plan deviation: createBranch \(name) is not the next reviewed action for \(fullName)")
                }
                if let existingSha = try await github.getRef(repo: fullName, ref: "heads/\(name)") {
                    // RESUME is registry-gated: only a branch THIS job
                    // created (it holds the receipt) may be continued on.
                    // Anything else with the same name is someone else's
                    // work — halt, touch nothing.
                    guard collector.isRegistryBranch(repo: fullName, name: name) else {
                        collector.haltRepo(fullName, status: .branchExists,
                                           reason: "branch \(name) already exists but was not created by this job — nothing written")
                        collector.audit(kind: "write.createBranch", repo: fullName,
                                        detail: "\(name) exists, not in this job's registry — halted")
                        throw GitHubClientError.http(409, "branch \(name) already exists in \(fullName)")
                    }
                    collector.consumeNextAction(repo: fullName)
                    collector.audit(kind: "write.createBranch", repo: fullName,
                                    detail: "\(name) already exists — resuming on it (ARMED)")
                    return ["sha": existingSha]
                }
                let newSha = try await github.createBranch(repo: fullName, name: name, fromSha: sha)
                collector.consumeNextAction(repo: fullName)
                collector.recordArtifact(Artifact(kind: .branch, repo: fullName, name: name))
                collector.audit(kind: "write.createBranch", repo: fullName,
                                detail: "\(name) from \(String(sha.prefix(12))) (ARMED)")
                return ["sha": newSha]
            }
        }
        gh.setObject(unsafeBitCast(createBranch, to: AnyObject.self),
                     forKeyedSubscript: "createBranch" as NSString)

        let putContent: @convention(block) (JSValue?, JSValue?, JSValue?, JSValue?) -> JSValue = { repoValue, pathValue, contentValue, optsValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("putContent: repo is required")
            }
            guard let path = stringArg(pathValue), let content = stringArg(contentValue) else {
                return rejectedPromise("putContent: path and content are required")
            }
            guard let opts = optsValue, opts.isObject,
                  let branch = stringArg(opts.objectForKeyedSubscript("branch")),
                  let message = stringArg(opts.objectForKeyedSubscript("message")) else {
                return rejectedPromise("putContent: opts { branch, message } are required")
            }
            guard branch.hasPrefix("bulkgh/") else {
                return rejectedPromise("putContent: writes are only allowed on \"bulkgh/\"-prefixed branches (host rule)")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                try preflight(fullName)
                guard case .putContent(let expectedPath, let expectedBranch, _, let expectedBefore, let expectedAfter)?
                        = collector.expectedNextAction(repo: fullName),
                      expectedPath == path, expectedBranch == branch else {
                    collector.haltRepo(fullName, status: .conflicted,
                                       reason: "script deviated from the reviewed plan (putContent \(path)) — nothing written")
                    throw GitHubClientError.http(409, "plan deviation: putContent \(path) is not the next reviewed action for \(fullName)")
                }
                // RESUME: an earlier armed run already committed exactly the
                // reviewed content to the job branch — skip, don't re-write.
                if let onBranch = try? await github.getContent(repo: fullName, path: path, ref: branch),
                   onBranch == expectedAfter {
                    collector.consumeNextAction(repo: fullName)
                    collector.audit(kind: "write.putContent", repo: fullName,
                                    detail: "\(path) on \(branch) already matches the reviewed plan — resumed, nothing written")
                    return nil
                }
                // Drift guard, both directions: the remote must still match
                // what the review saw, and the script must produce exactly
                // what the review approved.
                let current = try await github.getContent(repo: fullName, path: path, ref: nil)
                guard current == expectedBefore else {
                    collector.haltRepo(fullName, status: .conflicted,
                                       reason: "\(path) changed on the remote since the reviewed dry run — re-run the dry run and review again")
                    throw GitHubClientError.http(409, "drift: \(path) in \(fullName) no longer matches the reviewed dry run")
                }
                guard content == expectedAfter else {
                    collector.haltRepo(fullName, status: .conflicted,
                                       reason: "script produced different content for \(path) than the reviewed plan — nothing written")
                    throw GitHubClientError.http(409, "plan deviation: content for \(path) differs from the reviewed plan")
                }
                let commit = try await github.putContent(repo: fullName, path: path, content: content,
                                                         branch: branch, message: message)
                collector.consumeNextAction(repo: fullName)
                collector.audit(kind: "write.putContent", repo: fullName,
                                detail: "\(path) on \(branch) → \(String(commit.prefix(12))) (ARMED)")
                return nil
            }
        }
        gh.setObject(unsafeBitCast(putContent, to: AnyObject.self),
                     forKeyedSubscript: "putContent" as NSString)

        let deleteContent: @convention(block) (JSValue?, JSValue?, JSValue?) -> JSValue = { repoValue, pathValue, optsValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("deleteContent: repo is required")
            }
            guard let path = stringArg(pathValue) else {
                return rejectedPromise("deleteContent: path is required")
            }
            guard let opts = optsValue, opts.isObject,
                  let branch = stringArg(opts.objectForKeyedSubscript("branch")),
                  let message = stringArg(opts.objectForKeyedSubscript("message")) else {
                return rejectedPromise("deleteContent: opts { branch, message } are required")
            }
            guard branch.hasPrefix("bulkgh/") else {
                return rejectedPromise("deleteContent: writes are only allowed on \"bulkgh/\"-prefixed branches (host rule)")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                try preflight(fullName)
                guard case .deleteFile(let expectedPath, let expectedBranch, _, let expectedBefore)?
                        = collector.expectedNextAction(repo: fullName),
                      expectedPath == path, expectedBranch == branch else {
                    collector.haltRepo(fullName, status: .conflicted,
                                       reason: "script deviated from the reviewed plan (deleteContent \(path)) — nothing written")
                    throw GitHubClientError.http(409, "plan deviation: deleteContent \(path) is not the next reviewed action for \(fullName)")
                }
                // RESUME: an earlier armed run already removed this file from the
                // job branch — skip, don't re-delete.
                if (try? await github.getContent(repo: fullName, path: path, ref: branch)) == .some(nil) {
                    collector.consumeNextAction(repo: fullName)
                    collector.audit(kind: "write.deleteContent", repo: fullName,
                                    detail: "\(path) already absent on \(branch) — resumed, nothing written")
                    return nil
                }
                // Drift guard: the file must still match what the review saw on
                // the default branch — if it changed (or vanished), re-review.
                let current = try await github.getContent(repo: fullName, path: path, ref: nil)
                guard current == expectedBefore else {
                    collector.haltRepo(fullName, status: .conflicted,
                                       reason: "\(path) changed on the remote since the reviewed dry run — re-run the dry run and review again")
                    throw GitHubClientError.http(409, "drift: \(path) in \(fullName) no longer matches the reviewed dry run")
                }
                let commit = try await github.deleteContent(repo: fullName, path: path,
                                                            branch: branch, message: message)
                collector.consumeNextAction(repo: fullName)
                collector.audit(kind: "write.deleteContent", repo: fullName,
                                detail: "\(path) on \(branch) → \(String(commit.prefix(12))) (ARMED)")
                return nil
            }
        }
        gh.setObject(unsafeBitCast(deleteContent, to: AnyObject.self),
                     forKeyedSubscript: "deleteContent" as NSString)

        let createPR: @convention(block) (JSValue?, JSValue?) -> JSValue = { repoValue, optsValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("createPR: repo is required")
            }
            guard let opts = optsValue, opts.isObject,
                  let head = stringArg(opts.objectForKeyedSubscript("head")),
                  let rawTitle = stringArg(opts.objectForKeyedSubscript("title")),
                  let rawBody = stringArg(opts.objectForKeyedSubscript("body")) else {
                return rejectedPromise("createPR: opts { head, title, body } are required")
            }
            // Host-authoritative PR title/body: the user's reviewed fields win
            // over whatever the script passed, when set. Applied identically to
            // the dry-run path so the recorded plan and armed conformance match.
            let title = (prTitleOverride?.isEmpty == false) ? prTitleOverride! : rawTitle
            let body = (prBodyOverride?.isEmpty == false) ? prBodyOverride! : rawBody
            guard head.hasPrefix("bulkgh/") else {
                return rejectedPromise("createPR: head must be a \"bulkgh/\"-prefixed branch (host rule)")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                try preflight(fullName)
                guard case .createPR(let expectedHead, let expectedTitle, let expectedBody)?
                        = collector.expectedNextAction(repo: fullName),
                      expectedHead == head, expectedTitle == title, expectedBody == body else {
                    collector.haltRepo(fullName, status: .conflicted,
                                       reason: "script deviated from the reviewed plan (createPR from \(head)) — nothing written")
                    throw GitHubClientError.http(409, "plan deviation: createPR from \(head) does not match the reviewed plan for \(fullName)")
                }
                // Only react to a PR whose head ACTUALLY matches — never let a
                // mis-filtered listPRs (e.g. an unrelated open PR) trigger a
                // false "PR exists" halt or, worse, get adopted as ours.
                if let existing = try await github.listPRs(repo: fullName, head: head, state: "open")
                    .first(where: { $0.headRef == head }) {
                    // RESUME: the job's own PR from an earlier armed run.
                    if collector.isRegistryPR(repo: fullName, number: existing.number) {
                        collector.consumeNextAction(repo: fullName)
                        collector.upsert(repo: collector.repo(named: fullName), status: .prRaised,
                                         reason: "PR #\(existing.number) already open — resumed: \(existing.url)")
                        collector.audit(kind: "write.createPR", repo: fullName,
                                        detail: "#\(existing.number) already open — resumed (ARMED)")
                        return existing.scriptValue
                    }
                    // RECONCILE: an open PR already exists for a branch THIS
                    // job created (head is a registry branch) but the PR isn't
                    // in our registry — adopt it rather than orphaning the
                    // branch. This is the exact state that previously bricked a
                    // job: a branch with no reachable PR. Loud audit so the
                    // underlying "why did a PR already exist" stays visible.
                    if collector.isRegistryBranch(repo: fullName, name: head) {
                        collector.consumeNextAction(repo: fullName)
                        collector.recordArtifact(Artifact(kind: .pullRequest, repo: fullName,
                                                          name: "#\(existing.number)", url: existing.url))
                        collector.upsert(repo: collector.repo(named: fullName), status: .prRaised,
                                         reason: "PR #\(existing.number) already open for our branch — adopted: \(existing.url)")
                        collector.audit(kind: "write.createPR.reconciled", repo: fullName,
                                        detail: "#\(existing.number) already existed for \(head) — adopted into registry (ARMED)")
                        return existing.scriptValue
                    }
                    collector.haltRepo(fullName, status: .prExists,
                                       reason: "PR #\(existing.number) already open for \(head) but not created by this job: \(existing.url)")
                    throw GitHubClientError.http(409, "a PR already exists for \(head) in \(fullName)")
                }
                // Authoritative base branch — never assume main.
                let repoMeta = try await github.getRepo(fullName: fullName)
                collector.remember(repoMeta)
                let pr = try await github.createPR(repo: fullName, head: head,
                                                   base: repoMeta.defaultBranch,
                                                   title: title, body: body)
                collector.consumeNextAction(repo: fullName)
                collector.recordArtifact(Artifact(kind: .pullRequest, repo: fullName,
                                                  name: "#\(pr.number)", url: pr.url))
                collector.upsert(repo: collector.repo(named: fullName), status: .prRaised,
                                 reason: "PR #\(pr.number) — \(pr.url)")
                collector.audit(kind: "write.createPR", repo: fullName,
                                detail: "#\(pr.number) \(pr.url) (ARMED)")
                return pr.scriptValue
            }
        }
        gh.setObject(unsafeBitCast(createPR, to: AnyObject.self),
                     forKeyedSubscript: "createPR" as NSString)

        // Custom-property write (ARMED). A direct, terminal repo-metadata write
        // (no branch/PR). Guarded by, in order: repo selection, halt state,
        // plan conformance (same target values), allowed-values, idempotent
        // resume (already at target → nothing written), and a drift guard (the
        // values must still match what the dry run reviewed).
        let setProperties: @convention(block) (JSValue?, JSValue?) -> JSValue = { repoValue, valuesValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("setProperties: repo is required")
            }
            guard let desired = parsePropertyValues(valuesValue), !desired.isEmpty else {
                return rejectedPromise("setProperties: a non-empty values object { name: value } is required")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                try preflight(fullName)
                guard case .setProperties(let expectedValues, let expectedBefore)? = collector.expectedNextAction(repo: fullName),
                      expectedValues == desired else {
                    collector.haltRepo(fullName, status: .conflicted,
                                       reason: "script deviated from the reviewed plan (setProperties) — nothing written")
                    throw GitHubClientError.http(409, "plan deviation: setProperties is not the next reviewed action for \(fullName)")
                }
                let defs = try await propertyDefs(collector: collector, github: github, organisation: organisation)
                if let problem = validateValues(desired, against: defs) {
                    collector.haltRepo(fullName, status: .failed, reason: problem)
                    throw GitHubClientError.http(422, problem)
                }
                let keys = Array(desired.keys)
                let current = subset(try await github.getProperties(repo: fullName), keys: keys)
                if current == desired {
                    // RESUME / idempotent: already at target — nothing to write.
                    collector.consumeNextAction(repo: fullName)
                    collector.upsert(repo: collector.repo(named: fullName), status: .alreadyUpToDate,
                                     reason: "custom properties already at target — nothing written")
                    collector.audit(kind: "write.setProperties", repo: fullName,
                                    detail: "already at target — resumed, nothing written (ARMED)")
                    return nil
                }
                guard current == subset(expectedBefore, keys: keys) else {
                    collector.haltRepo(fullName, status: .conflicted,
                                       reason: "custom properties changed on the remote since the reviewed dry run — re-run the dry run and review again")
                    throw GitHubClientError.http(409, "drift: custom properties for \(fullName) no longer match the reviewed dry run")
                }
                try await github.setProperties(repo: fullName, values: desired)
                collector.consumeNextAction(repo: fullName)
                collector.upsert(repo: collector.repo(named: fullName), status: .updated,
                                 reason: "custom properties set: \(keys.sorted().joined(separator: ", "))")
                collector.audit(kind: "write.setProperties", repo: fullName,
                                detail: "\(desired.count) propert\(desired.count == 1 ? "y" : "ies") (ARMED)")
                return nil
            }
        }
        gh.setObject(unsafeBitCast(setProperties, to: AnyObject.self),
                     forKeyedSubscript: "setProperties" as NSString)
    }

    // MARK: - Merge surface (registry-scoped)

    /// The merge-phase surface. EVERYTHING here is scoped to the job's
    /// artifact registry — a merge script cannot touch a PR or branch the
    /// job didn't create. Merging additionally requires the user's in-app
    /// approval AND that the head SHA still matches the approved one (an
    /// approval is for a specific state of the branch, host-enforced in
    /// both dry-run and armed modes so drift surfaces at review time).
    /// Dry run records a plan; armed conforms to that plan and executes.
    private static func installMergeSurface(on gh: JSValue, github: GitHubClient,
                                            collector: JobCollector,
                                            limiter: AsyncSemaphore, cancel: CancelBox,
                                            vmQueue: DispatchQueue, armed: Bool) {
        @Sendable func preflight(_ repo: String) throws {
            guard armed else { return }
            if collector.isOutsideCanary(repo) {
                collector.haltRepo(repo, status: .skipped,
                                   reason: "not selected for writes — nothing merged")
                throw GitHubClientError.http(403, "\(repo) is not selected for this armed run")
            }
            if collector.isHalted(repo) {
                throw GitHubClientError.http(409, "writes to \(repo) were halted earlier in this run")
            }
        }

        /// Armed mode: the call must be the next action of the reviewed plan.
        @Sendable func conform(_ repo: String, _ action: PlannedAction) throws {
            guard armed else { return }
            guard collector.expectedNextAction(repo: repo) == action else {
                collector.haltRepo(repo, status: .conflicted,
                                   reason: "script deviated from the reviewed plan (\(action.summary)) — nothing further done")
                throw GitHubClientError.http(409, "plan deviation: \(action.summary) is not the next reviewed action for \(repo)")
            }
        }

        let listJobPRs: @convention(block) () -> JSValue = {
            hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                var prs: [PullRequestRef] = []
                for entry in collector.registryPRs {
                    let pr = try await github.getPR(repo: entry.repo, number: entry.number)
                    prs.append(pr)
                }
                collector.audit(kind: "gh.listJobPRs", repo: nil,
                                detail: "→ \(prs.count) registry PR(s)")
                return prs.map(\.scriptValue)
            }
        }
        gh.setObject(unsafeBitCast(listJobPRs, to: AnyObject.self),
                     forKeyedSubscript: "listJobPRs" as NSString)

        let listJobBranches: @convention(block) () -> JSValue = {
            hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let branches = collector.registryBranches.map {
                    ["repo": $0.repo, "name": $0.name]
                }
                collector.audit(kind: "gh.listJobBranches", repo: nil,
                                detail: "→ \(branches.count) registry branch(es)")
                return branches
            }
        }
        gh.setObject(unsafeBitCast(listJobBranches, to: AnyObject.self),
                     forKeyedSubscript: "listJobBranches" as NSString)

        let mergePR: @convention(block) (JSValue?, JSValue?, JSValue?) -> JSValue = { repoValue, numberValue, optsValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("mergePR: repo is required")
            }
            guard let numberValue, numberValue.isNumber else {
                return rejectedPromise("mergePR: PR number is required")
            }
            let number = Int(numberValue.toInt32())
            guard let opts = optsValue, opts.isObject,
                  let expectedHeadSha = stringArg(opts.objectForKeyedSubscript("expectedHeadSha")) else {
                return rejectedPromise("mergePR: opts { expectedHeadSha } is required")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                try preflight(fullName)
                guard collector.isRegistryPR(repo: fullName, number: number) else {
                    throw GitHubClientError.http(403,
                        "PR #\(number) in \(fullName) is not in this job's artifact registry — merge scripts may only touch PRs the job created")
                }
                guard let approval = collector.approval(repo: fullName, number: number) else {
                    collector.haltRepo(fullName, status: .blocked,
                                       reason: "PR #\(number) is not approved — approve it in the app before merging")
                    throw GitHubClientError.http(403, "PR #\(number) in \(fullName) has no user approval")
                }
                // Approval drift guard FIRST: the branch must still be exactly
                // what the user approved. (Checked before the script's
                // expectedHeadSha so a moved branch reads as drift, not as
                // the script passing a wrong value — listJobPRs hands the
                // script the current sha.)
                let current = try await github.getPR(repo: fullName, number: number)
                guard current.headSha == approval.headSha else {
                    collector.haltRepo(fullName, status: .conflicted,
                                       reason: "PR #\(number) head moved since approval — re-review and approve again")
                    throw GitHubClientError.http(409, "PR #\(number) head moved since approval")
                }
                guard approval.headSha == expectedHeadSha else {
                    collector.haltRepo(fullName, status: .conflicted,
                                       reason: "PR #\(number): the script's expectedHeadSha differs from the approved SHA")
                    throw GitHubClientError.http(409, "expectedHeadSha does not match the approved SHA for PR #\(number)")
                }
                let action = PlannedAction.mergePR(number: number, expectedHeadSha: expectedHeadSha)
                if armed {
                    try conform(fullName, action)
                    let sha: String
                    do {
                        sha = try await github.mergePR(repo: fullName, number: number,
                                                       expectedHeadSha: expectedHeadSha)
                    } catch let GitHubClientError.http(code, _) where code == 405 || code == 409 {
                        // 405 = the branch conflicts with base (not mergeable);
                        // 409 = head moved. Surface per-repo as .conflicted with
                        // an actionable reason rather than failing the whole run.
                        let reason = code == 405
                            ? "PR #\(number) can't be merged — the branch conflicts with the base. Resolve it (or update the branch from base) on GitHub, then re-approve and re-run Complete."
                            : "PR #\(number) head moved — re-review and approve again."
                        collector.haltRepo(fullName, status: .conflicted, reason: reason)
                        throw GitHubClientError.http(code, "PR #\(number) in \(fullName) is not mergeable")
                    }
                    collector.consumeNextAction(repo: fullName)
                    collector.upsert(repo: collector.repo(named: fullName), status: .merged,
                                     reason: "PR #\(number) squash-merged as \(String(sha.prefix(12)))")
                    collector.audit(kind: "write.mergePR", repo: fullName,
                                    detail: "#\(number) → \(String(sha.prefix(12))) (ARMED)")
                    return ["sha": sha]
                } else {
                    collector.recordAction(repo: fullName, action)
                    collector.audit(kind: "plan.mergePR", repo: fullName,
                                    detail: "#\(number) at \(String(expectedHeadSha.prefix(12))) (dry-run)")
                    return ["sha": syntheticSha("\(fullName)#\(number)#merge")]
                }
            }
        }
        gh.setObject(unsafeBitCast(mergePR, to: AnyObject.self),
                     forKeyedSubscript: "mergePR" as NSString)

        let closePR: @convention(block) (JSValue?, JSValue?) -> JSValue = { repoValue, numberValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("closePR: repo is required")
            }
            guard let numberValue, numberValue.isNumber else {
                return rejectedPromise("closePR: PR number is required")
            }
            let number = Int(numberValue.toInt32())
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                try preflight(fullName)
                guard collector.isRegistryPR(repo: fullName, number: number) else {
                    throw GitHubClientError.http(403,
                        "PR #\(number) in \(fullName) is not in this job's artifact registry")
                }
                let action = PlannedAction.closePR(number: number)
                if armed {
                    try conform(fullName, action)
                    try await github.closePR(repo: fullName, number: number)
                    collector.consumeNextAction(repo: fullName)
                    collector.upsert(repo: collector.repo(named: fullName), status: .cancelled,
                                     reason: "PR #\(number) closed without merging")
                    collector.audit(kind: "write.closePR", repo: fullName,
                                    detail: "#\(number) (ARMED)")
                } else {
                    collector.recordAction(repo: fullName, action)
                    collector.audit(kind: "plan.closePR", repo: fullName,
                                    detail: "#\(number) (dry-run)")
                }
                return nil
            }
        }
        gh.setObject(unsafeBitCast(closePR, to: AnyObject.self),
                     forKeyedSubscript: "closePR" as NSString)

        let editPR: @convention(block) (JSValue?, JSValue?, JSValue?) -> JSValue = { repoValue, numberValue, bodyValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("editPR: repo is required")
            }
            guard let numberValue, numberValue.isNumber else {
                return rejectedPromise("editPR: PR number is required")
            }
            let number = Int(numberValue.toInt32())
            guard let body = stringArg(bodyValue) else {
                return rejectedPromise("editPR: body is required")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                try preflight(fullName)
                guard collector.isRegistryPR(repo: fullName, number: number) else {
                    throw GitHubClientError.http(403,
                        "PR #\(number) in \(fullName) is not in this job's artifact registry")
                }
                let action = PlannedAction.editPR(number: number, body: body)
                if armed {
                    try conform(fullName, action)
                    try await github.editPR(repo: fullName, number: number, body: body)
                    collector.consumeNextAction(repo: fullName)
                    collector.upsert(repo: collector.repo(named: fullName), status: .prRaised,
                                     reason: "PR #\(number) body updated")
                    collector.audit(kind: "write.editPR", repo: fullName,
                                    detail: "#\(number) body updated (\(body.count) chars) (ARMED)")
                } else {
                    collector.recordAction(repo: fullName, action)
                    collector.audit(kind: "plan.editPR", repo: fullName,
                                    detail: "#\(number) body (\(body.count) chars) (dry-run)")
                }
                return nil
            }
        }
        gh.setObject(unsafeBitCast(editPR, to: AnyObject.self),
                     forKeyedSubscript: "editPR" as NSString)

        let deleteBranch: @convention(block) (JSValue?, JSValue?) -> JSValue = { repoValue, nameValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("deleteBranch: repo is required")
            }
            guard let name = stringArg(nameValue) else {
                return rejectedPromise("deleteBranch: branch name is required")
            }
            guard name.hasPrefix("bulkgh/") else {
                return rejectedPromise("deleteBranch: only \"bulkgh/\"-prefixed job branches can be deleted (host rule)")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                try preflight(fullName)
                guard collector.isRegistryBranch(repo: fullName, name: name) else {
                    throw GitHubClientError.http(403,
                        "branch \(name) in \(fullName) is not in this job's artifact registry")
                }
                let action = PlannedAction.deleteBranch(name: name)
                if armed {
                    try conform(fullName, action)
                    try await github.deleteBranch(repo: fullName, name: name)
                    collector.consumeNextAction(repo: fullName)
                    // Record the deletion so the app drops this branch's
                    // registry artifact — the only way an orphan branch (no PR,
                    // so its repo never reaches a merged/cancelled status) can
                    // leave the registry.
                    collector.recordConsumedBranch(repo: fullName, name: name)
                    collector.audit(kind: "write.deleteBranch", repo: fullName,
                                    detail: "\(name) (ARMED)")
                } else {
                    collector.recordAction(repo: fullName, action)
                    collector.audit(kind: "plan.deleteBranch", repo: fullName,
                                    detail: "\(name) (dry-run)")
                }
                return nil
            }
        }
        gh.setObject(unsafeBitCast(deleteBranch, to: AnyObject.self),
                     forKeyedSubscript: "deleteBranch" as NSString)
    }

    /// Deterministic fake SHA for synthesized dry-run responses.
    private static func syntheticSha(_ basis: String) -> String {
        let hash = basis.unicodeScalars.reduce(into: UInt64(5381)) {
            $0 = ($0 << 5) &+ $0 &+ UInt64($1.value)
        }
        return String(format: "%016llx%016llx", hash, ~hash)
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
            guard collector.hasReceipt(repo: ref.fullName, path: path)
                    || collector.hasPropertyReceipt(repo: ref.fullName) else {
                ctx.exception = JSValue(newErrorFromMessage:
                    "reportMatch: no authoritative read for \(ref.fullName) \(path) — call gh.getContent (for files) or gh.getProperties/gh.listOrgProperties (for custom properties) first; search results are candidates, not proof",
                    in: ctx)
                return
            }
            let explanation = stringArg(evidenceValue.objectForKeyedSubscript("explanation"))
            var evidence = Evidence(path: path, excerpt: excerpt, explanation: explanation)
            // The receipt rule guarantees the file content is cached; locate
            // the match against the real bytes so the review pane can show it
            // in situ and highlight exactly the matched lines — the UI never
            // re-guesses the match from the excerpt.
            if let content = collector.fetchedContent(repo: ref.fullName, path: path) {
                if let loc = locateMatch(around: excerpt, in: content) {
                    evidence.context = loc.text
                    evidence.contextStartLine = loc.startLine
                    evidence.matchLines = loc.matchLines
                    evidence.noSpecificLine = loc.noSpecificLine
                } else {
                    // Excerpt isn't present verbatim (e.g. the script normalised
                    // whitespace): show it as-is rather than nothing, and flag
                    // that there's no located line to highlight.
                    evidence.context = excerpt
                    evidence.contextStartLine = 1
                    evidence.noSpecificLine = true
                }
            }
            collector.upsert(repo: ref, status: .verifiedMatch, reason: explanation, evidence: evidence)
            collector.audit(kind: "job.reportMatch", repo: ref.fullName, detail: path)
        }
        job.setObject(unsafeBitCast(reportMatch, to: AnyObject.self),
                      forKeyedSubscript: "reportMatch" as NSString)

        let skip: @convention(block) (JSValue?, JSValue?) -> Void = { repoValue, reasonValue in
            guard let repoValue, let ref = resolveRepo(repoValue, collector: collector) else { return }
            // The host's halt verdict (conflicted/drift/already-exists/not
            // selected) outranks the script's bookkeeping: the script's catch
            // block reports the thrown refusal, which must not relabel it.
            guard !collector.isHalted(ref.fullName) else { return }
            let reason = describe(reasonValue) ?? "skipped"
            collector.upsert(repo: ref, status: .skipped, reason: reason)
        }
        job.setObject(unsafeBitCast(skip, to: AnyObject.self), forKeyedSubscript: "skip" as NSString)

        let fail: @convention(block) (JSValue?, JSValue?) -> Void = { repoValue, messageValue in
            guard let repoValue, let ref = resolveRepo(repoValue, collector: collector) else { return }
            let message = describe(messageValue) ?? "error"
            guard !collector.isHalted(ref.fullName) else {
                collector.audit(kind: "job.error", repo: ref.fullName,
                                detail: "(script report after host halt) \(message)")
                return
            }
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

    /// Where a reported match sits inside the fetched file content, resolved
    /// against the real bytes so the review pane never re-guesses it. Returns
    /// the context window to show, its 1-based start line, the absolute line
    /// numbers to highlight, and whether the match has no single line to point
    /// at (a whole-file excerpt). Located by the excerpt's first non-empty
    /// line; nil when the excerpt is blank or can't be found, in which case the
    /// caller falls back to showing the excerpt itself.
    static func locateMatch(around excerpt: String, in content: String,
                            radius: Int = 3)
        -> (text: String, startLine: Int, matchLines: [Int], noSpecificLine: Bool)? {
        let fileLines = content.components(separatedBy: "\n")
        let trimmedFile = fileLines.map { $0.trimmingCharacters(in: .whitespaces) }
        let nonEmptyFileCount = trimmedFile.filter { !$0.isEmpty }.count
        let excerptLines = excerpt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let firstNeedle = excerptLines.first else { return nil }

        // A whole-file excerpt points at no single line: highlight nothing and
        // let the caller caption it, rather than lighting up the whole window.
        if nonEmptyFileCount > 0, excerptLines.count >= nonEmptyFileCount {
            let end = min(fileLines.count, radius * 2 + 1)
            return (fileLines[0..<end].joined(separator: "\n"), 1, [], true)
        }

        guard let anchor = trimmedFile.firstIndex(where: { $0.contains(firstNeedle) })
        else { return nil }

        // The same window the review pane has always shown: a few lines either
        // side of the match, with the excerpt's own span capped so it can't
        // widen the window without bound.
        let excerptSpan = min(excerptLines.count, 8)
        let lo = max(0, anchor - radius)
        let hi = min(fileLines.count, anchor + excerptSpan + radius)
        let excerptSet = Set(excerptLines)
        var matched = (lo..<hi)
            .filter { !trimmedFile[$0].isEmpty && excerptSet.contains(trimmedFile[$0]) }
            .map { $0 + 1 }
        // A sub-line fragment matches no whole line; highlight the located line.
        if matched.isEmpty { matched = [anchor + 1] }
        return (fileLines[lo..<hi].joined(separator: "\n"), lo + 1, matched, false)
    }

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

    // MARK: Custom-property helpers

    /// Parses a JS values object `{ name: value }` into PropertyValues. A JS
    /// string → `.string`, an array → `.list`, null → `.null` (clears it).
    /// Returns nil when the argument is not an object.
    static func parsePropertyValues(_ value: JSValue?) -> [String: PropertyValue]? {
        guard let value, value.isObject, !value.isNull,
              let dict = value.toObject() as? [String: Any] else { return nil }
        var out: [String: PropertyValue] = [:]
        for (key, raw) in dict { out[key] = propertyValue(fromAny: raw) }
        return out
    }

    static func propertyValue(fromAny raw: Any) -> PropertyValue {
        switch raw {
        case let s as String: return .string(s)
        case let a as [Any]: return .list(a.map { String(describing: $0) })
        case is NSNull: return .null
        default: return .string(String(describing: raw))
        }
    }

    /// The values for exactly `keys`, with an absent key read as `.null` — so
    /// "before"/"current"/"desired" maps compare on the same key set.
    static func subset(_ map: [String: PropertyValue], keys: [String]) -> [String: PropertyValue] {
        var out: [String: PropertyValue] = [:]
        for key in keys { out[key] = map[key] ?? .null }
        return out
    }

    /// Org property definitions, fetched once per run and reused.
    static func propertyDefs(collector: JobCollector, github: GitHubClient,
                             organisation: String) async throws -> [PropertyDef] {
        if let cached = collector.cachedPropertyDefs() { return cached }
        let defs = try await github.listPropertyDefs(org: organisation)
        collector.cachePropertyDefs(defs)
        return defs
    }

    /// Host-authoritative validation: the property must be defined (v1 sets
    /// values only) and single/multi-select values must be in the allowed set.
    /// Returns a human-readable problem, or nil when every value is valid.
    static func validateValues(_ values: [String: PropertyValue],
                               against defs: [PropertyDef]) -> String? {
        for (name, value) in values {
            guard let def = defs.first(where: { $0.name == name }) else {
                return "custom property \"\(name)\" is not defined in the organisation — define it in org settings first (v1 sets values only)"
            }
            guard let allowed = def.allowedValues, !allowed.isEmpty else { continue }
            switch value {
            case .string(let s):
                if !allowed.contains(s) {
                    return "\"\(s)\" is not an allowed value for \"\(name)\" (allowed: \(allowed.joined(separator: ", ")))"
                }
            case .list(let arr):
                if let bad = arr.first(where: { !allowed.contains($0) }) {
                    return "\"\(bad)\" is not an allowed value for \"\(name)\" (allowed: \(allowed.joined(separator: ", ")))"
                }
            case .null:
                continue
            }
        }
        return nil
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
