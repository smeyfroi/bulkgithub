import Foundation
import Observation
import BulkGitHubKit

@MainActor
@Observable
final class AppModel {
    var settings = AppSettings()
    /// The selected job phase: drives what kind of script Generate requests.
    /// Kept in sync with the editor — validating or loading a script adopts
    /// its declared phase.
    var phase: JobPhase = .check
    var prompt: String = ""
    var scriptText: String = ""
    var paramsDraft: [String: String] = [:]
    /// PR title/description for update jobs — REQUIRED (see prFieldsComplete),
    /// pre-filled from the generated script, and host-authoritative: passed to
    /// the engine as prTitleOverride/prBodyOverride so every created PR uses
    /// them regardless of what the script passes to gh.createPR.
    var prTitle: String = ""
    var prBody: String = ""
    /// Canary target: when set, update runs are confined to this one repo.
    var canaryRepo: String = ""
    /// Cross-phase job state (JSON per key) — written by check runs, read by
    /// update runs so they don't repeat the search.
    var jobState: [String: String] = [:]
    var quotaText: String?
    /// "resets in 23 min" for the displayed quota pool — surfaced when the
    /// budget is exhausted so the user knows when to come back.
    var quotaResetText: String?
    /// Set while a run is paused by the quota gate (quota nearly spent). Drives
    /// the pause banner; nil when the run is proceeding normally.
    var quotaPauseText: String?
    /// true when the pause is beyond the auto-wait cap and is holding for a
    /// manual Resume rather than auto-resuming at the reset.
    var quotaPauseIsHeld: Bool = false
    /// Live "retrying GitHub…" line shown while a run grinds through transient
    /// errors — nil when nothing is retrying (or in fixture mode).
    var retryText: String?
    /// Each phase is its own workspace — prompt, script, and params swap
    /// together on a phase switch, so editing the update script can never
    /// make check state look stale (and vice versa). The check → update
    /// links that remain are deliberate: carried job state and the funnel
    /// rows in the update table.
    private var promptsByPhase: [JobPhase: String] = [:]
    private var scriptsByPhase: [JobPhase: String] = [:]
    private var paramsByPhase: [JobPhase: [String: String]] = [:]
    var diagnostics: [Diagnostic] = []
    /// Results are kept per phase: switching Check ↔ Update shows each
    /// phase's own last run instead of leaking one phase's table into the
    /// other.
    private(set) var resultsByPhase: [JobPhase: [RepoResult]] = [:]
    /// The script source that produced each phase's results, for staleness:
    /// regenerating or editing the script makes existing results stale.
    private var ranScriptByPhase: [JobPhase: String] = [:]
    /// The effective params each phase's results were produced with —
    /// param edits change what the script computes just like source edits,
    /// so they trigger the same staleness.
    private var ranParamsByPhase: [JobPhase: [String: String]] = [:]
    /// The defaults declared in the script's meta.params (captured at
    /// validation), so the params bar can mark edited values and offer a
    /// reset back to the script's own default.
    private var declaredParamsByPhase: [JobPhase: [String: String]] = [:]
    var results: [RepoResult] { resultsByPhase[phase] ?? [] }
    var logs: [String] = []
    var auditEvents: [AuditEvent] = []
    /// Cumulative across all runs of this job (capped), each run prefixed
    /// with a synthetic boundary event — the job's full audit trail.
    var auditTrail: [AuditEvent] = []
    var plannedActions: [String: [PlannedAction]] = [:]
    /// The phase whose dry run produced plannedActions: the update plan must
    /// not leak into the merge phase's Apply flow (and vice versa).
    var plannedActionsPhase: JobPhase?
    /// The reviewed plan, visible only in the phase that produced it.
    var activePlan: [String: [PlannedAction]] {
        plannedActionsPhase == phase ? plannedActions : [:]
    }
    /// Remote objects armed runs of this job created (the artifact registry —
    /// merge/cancel operates only on these).
    var artifacts: [Artifact] = []
    /// Per-PR merge approvals, capturing the head SHA approved. Merging
    /// requires the head to still match — host-enforced.
    var approvals: [Approval] = []
    /// The reviewed plan as applied, per repo — what each job PR changes.
    /// Survives later dry runs (which replace the working plan) and
    /// restarts; cleared with the repo's artifacts when its PR is consumed.
    var appliedPlan: [String: [PlannedAction]] = [:]
    var statusLine: String = "Ready"
    var running = false
    /// True once the current run has enumerated repos (candidate rows). Drives
    /// the determinate scan meter: it stays determinate from the first
    /// candidate until the run ends, so the meter holds at 100% rather than
    /// blinking back to a spinner the instant the last candidate resolves.
    var runHadCandidates = false
    /// True while an ARMED run is executing — drives the loud mode banner.
    var currentRunIsArmed = false
    var showApplySheet = false
    /// Per-phase apply selection: which planned repos an armed run will target.
    /// Each phase keeps its OWN set, so navigating Update → Merge → Update
    /// never clobbers a deselection, and the merge selection never bleeds into
    /// update. Default-populated canary-first the moment a fresh plan lands;
    /// re-derived (never blindly cleared) on phase entry. Never persisted.
    var applyTargetsByPhase: [JobPhase: Set<String>] = [:]
    /// The apply selection for the current phase — what the table's checkbox
    /// column and the Apply sheet read.
    var applyTargets: Set<String> { applyTargetsByPhase[phase] ?? [] }
    /// The user-set write mode for the current phase: with it OFF, Run is a
    /// dry run; with it ON, Run applies the reviewed plan (via the
    /// confirmation sheet). Snaps back to dry run after every armed run and
    /// on any context change — each write is a deliberate act, never a
    /// sticky default. Never persisted.
    var writeArmed = false
    /// Write mode requires something reviewed to apply: a plan from this
    /// phase's dry run, not invalidated by script edits.
    var canArmWrites: Bool {
        phase != .check && !activePlan.isEmpty && !resultsAreStale
    }

    /// Repos eligible for an armed run: those the reviewed plan touches, in a
    /// stable order for the header count and select-all.
    var plannedRepoIDs: [String] { activePlan.keys.sorted() }

    /// Default the apply selection canary-first: just the canary when it has a
    /// plan, otherwise every planned repo. Called whenever a fresh plan lands;
    /// the table's checkbox column and the Apply sheet read `applyTargets`.
    func refreshApplyTargets(force: Bool = false) {
        // Preserve this phase's existing (non-empty) selection unless forced by
        // a fresh plan — navigating away and back must never discard a
        // deselection the user made on purpose.
        if !force, !(applyTargetsByPhase[phase] ?? []).isEmpty { return }
        // Canary-first only in the update phase — canary confinement is
        // update-only. The merge phase defaults to every planned repo: the
        // approval queue, not the canary, is its real per-PR selection, so a
        // stray canary must never silently narrow an armed merge to one PR.
        if phase == .update, !canaryRepo.isEmpty, activePlan[canaryRepo] != nil {
            applyTargetsByPhase[phase] = [canaryRepo]
        } else {
            applyTargetsByPhase[phase] = Set(plannedRepoIDs)
        }
    }

    /// Select every planned repo for the armed run (current phase).
    func selectAllApplyTargets() { applyTargetsByPhase[phase] = Set(plannedRepoIDs) }

    /// Clear the armed-run selection (Apply then disables until one is chosen).
    func deselectAllApplyTargets() { applyTargetsByPhase[phase] = [] }

    /// Add or remove a repo from the current phase's armed-run selection.
    func toggleApplyTarget(_ repoID: String) {
        var set = applyTargetsByPhase[phase] ?? []
        if set.contains(repoID) { set.remove(repoID) } else { set.insert(repoID) }
        applyTargetsByPhase[phase] = set
    }

    /// The repos an armed apply actually targets, by phase: the user's checkbox
    /// selection in Update; the LIVE registry in Merge — where approvals (not a
    /// selection) gate what merges, so the scope must track the current
    /// registry, never a stale applyTargets snapshot left over from before a
    /// partial merge consumed artifacts.
    var armTargets: Set<String> {
        phase == .merge ? Set(mergeRows.map(\.artifact.repo)) : applyTargets
    }

    var generating = false
    var validating = false
    var selectedRepo: String?

    @ObservationIgnored let credentials: CredentialStore
    @ObservationIgnored private let store = AppStateStore()
    @ObservationIgnored private let engine = ScriptEngine()
    @ObservationIgnored private let rateLimit = RateLimitMonitor()
    @ObservationIgnored private let retryMonitor = RetryMonitor()
    /// Session-lived so their benefit spans runs: the ETag cache makes re-scans
    /// nearly free against quota, and the pacer keeps armed runs under GitHub's
    /// secondary write limit. Shared across every client this session builds.
    @ObservationIgnored private let etagCache = ETagCache()
    @ObservationIgnored private let writePacer = WritePacer()
    /// Proactive rate-limit gate: pauses a run as quota runs out and resumes
    /// when the window resets. lazy because it reads the session's rateLimit.
    @ObservationIgnored private lazy var quotaGate = QuotaGate(rateLimit: rateLimit)
    /// One-shot guard so a held (beyond-cap) pause notifies the walked-away user
    /// exactly once per run, not on every poll tick.
    @ObservationIgnored private var notifiedHeldPause = false
    @ObservationIgnored private var githubSession = LiveGitHubClient.makeSession()
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// In-flight validation, joinable: Run during the post-generation
    /// auto-validate waits for that result instead of silently bailing.
    @ObservationIgnored private var validationTask: Task<ValidatedScript?, Never>?
    /// Bumped per run; engine events carry the generation they belong to, so
    /// stragglers arriving after the final snapshot can't re-append stale rows
    /// or duplicate log lines.
    @ObservationIgnored private var runGeneration = 0
    @ObservationIgnored private let typescript = TypeScriptService.loadDefault()
    @ObservationIgnored private lazy var pipeline = ValidationPipeline(typescript: typescript)

    init(credentials: CredentialStore = KeychainCredentialStore()) {
        self.credentials = credentials
        var restoredJob = false
        if let snapshot = store.load() {
            settings = snapshot.settings
            if let job = snapshot.job {
                restoredJob = true
                phase = job.phase
                promptsByPhase = Self.byPhase(job.promptsByPhase)
                scriptsByPhase = Self.byPhase(job.scriptsByPhase)
                paramsByPhase = Self.byPhase(job.paramsByPhase)
                resultsByPhase = Self.byPhase(job.resultsByPhase)
                ranScriptByPhase = Self.byPhase(job.ranScriptByPhase)
                ranParamsByPhase = Self.byPhase(job.ranParamsByPhase)
                declaredParamsByPhase = Self.byPhase(job.declaredParamsByPhase)
                // Pre-per-phase saves: attribute the legacy single slots to
                // the job's phase.
                if scriptsByPhase.isEmpty { scriptsByPhase[job.phase] = job.scriptSource }
                if paramsByPhase.isEmpty { paramsByPhase[job.phase] = job.params }
                if promptsByPhase.isEmpty { promptsByPhase[job.phase] = job.prompt }
                if resultsByPhase.isEmpty, !job.results.isEmpty {
                    resultsByPhase[job.phase] = job.results
                    ranScriptByPhase[job.phase] = job.scriptSource
                }
                prompt = promptsByPhase[job.phase] ?? ""
                scriptText = scriptsByPhase[job.phase] ?? ""
                paramsDraft = paramsByPhase[job.phase] ?? [:]
                logs = job.logs
                auditEvents = job.auditEvents
                auditTrail = job.auditTrail ?? []
                plannedActions = job.plannedActions ?? [:]
                plannedActionsPhase = job.planPhase.flatMap(JobPhase.init(rawValue:))
                    ?? (plannedActions.isEmpty ? nil : .update)  // legacy saves were update-only
                jobState = job.state ?? [:]
                prTitle = job.prTitle ?? ""
                prBody = job.prBody ?? ""
                canaryRepo = job.canaryRepo ?? ""
                artifacts = job.artifacts ?? []
                approvals = job.approvals ?? []
                appliedPlan = job.appliedPlans ?? [:]
                statusLine = job.lastRunStatus ?? "Restored previous job"
                // applyTargets isn't persisted; re-derive it from the restored
                // plan so a reviewed plan is applyable immediately after launch
                // (otherwise arming Write would show "0 of N selected").
                refreshApplyTargets()
            }
        }
        if !restoredJob {
            loadGoldenRecipe()
        }
        userRecipes = recipeStore.load()
    }

    private static func byPhase<T>(_ raw: [String: T]?) -> [JobPhase: T] {
        guard let raw else { return [:] }
        var mapped: [JobPhase: T] = [:]
        for (key, value) in raw {
            if let phase = JobPhase(rawValue: key) { mapped[phase] = value }
        }
        return mapped
    }

    private static func rawKeyed<T>(_ map: [JobPhase: T]) -> [String: T] {
        Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
    }

    var typeCheckingAvailable: Bool { typescript != nil }
    var typeCheckerLabel: String {
        guard typescript != nil else { return "Type-check unavailable" }
        if let version = typescript?.compilerVersion { return "TypeScript \(version)" }
        return "TypeScript ready"
    }

    /// Params shown in the editable strip — PR title/description have
    /// dedicated fields, so their raw params stay hidden.
    var visibleParamKeys: [String] {
        paramsDraft.keys.filter { $0 != "prTitle" && $0 != "prBody" }.sorted()
    }

    var selectedResult: RepoResult? {
        guard let selectedRepo else { return nil }
        if let result = results.first(where: { $0.id == selectedRepo }) { return result }
        // The update table carries check rows forward before any update run —
        // selecting one inspects its check evidence.
        if phase == .update {
            return resultsByPhase[.check]?.first { $0.id == selectedRepo }
        }
        // Merge rows exist before any merge run: selecting one inspects the
        // PR's receipts. "PR raised" is the true state of an artifact row.
        if phase == .merge, let row = mergeRows.first(where: { $0.id == selectedRepo }) {
            return row.result ?? RepoResult(repo: row.repo, status: .prRaised,
                                            reason: "PR \(row.artifact.name) awaiting merge")
        }
        return nil
    }

    /// The visible results were produced by a different script — or different
    /// params — than what's on screen now. Suppressed while generating or
    /// running: the script is mid-change then, so "stale" is noise; it
    /// reappears once the new script settles unrun. Starting a run clears
    /// the results, so the banner is gone the moment Run is pressed.
    var resultsAreStale: Bool { staleReason != nil }

    /// What changed since the visible results were produced (nil = nothing).
    var staleReason: String? {
        guard !generating, !running,
              !results.isEmpty, let ran = ranScriptByPhase[phase] else { return nil }
        let scriptChanged = ran != scriptText
        // Restored pre-0.4.5 state has no recorded params: unknown, not stale.
        let paramsChanged = ranParamsByPhase[phase].map { $0 != effectiveParams(for: phase) } ?? false
        switch (scriptChanged, paramsChanged) {
        case (true, true): return "The script and its parameters have changed since these results were produced — Run to refresh."
        case (true, false): return "The script has changed since these results were produced — Run to refresh."
        case (false, true): return "The parameters have changed since these results were produced — Run to refresh."
        case (false, false): return nil
        }
    }

    /// The params a run of `runPhase` would receive right now: the editable
    /// draft, plus the PR title/description fields. Mirrored by runInternal.
    private func effectiveParams(for runPhase: JobPhase) -> [String: String] {
        var params = paramsDraft
        // Inject the PR title/description unconditionally (no longer gated on
        // the script declaring matching params) so job.params carries them and
        // editing a field marks the reviewed plan stale. The host-authoritative
        // override in EngineConfiguration is what guarantees the created PR uses
        // these values regardless of what the script passes.
        if runPhase == .update, !prTitle.isEmpty {
            params["prTitle"] = prTitle
        }
        if runPhase == .update, !prBody.isEmpty {
            params["prBody"] = prBody
        }
        return params
    }

    /// In the update phase both PR fields must be filled before a run/apply —
    /// they are the host-authoritative source of the created PRs' title/body.
    /// Other phases never create PRs, so they are always "complete".
    var prFieldsComplete: Bool {
        phase != .update
            || (!prTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !prBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// The script's own default for a param (nil when unknown — e.g. the
    /// script hasn't been validated since it changed).
    func declaredDefault(for key: String) -> String? {
        declaredParamsByPhase[phase]?[key]
    }

    /// One row of the update table: the check verdict and the update outcome
    /// side by side, so the funnel (found by Check → planned by Update) is
    /// visible from the moment you switch phases — including the canary repo,
    /// before any update run has happened.
    struct UpdateRow: Identifiable {
        let repo: RepoRef
        let check: RepoResult?
        let update: RepoResult?
        var id: String { repo.fullName }
        // Non-optional status ordinals for table sorting; rows with no run yet
        // sort last.
        var checkOrder: Int { check?.status.sortOrder ?? Int.max }
        var updateOrder: Int { update?.status.sortOrder ?? Int.max }
    }

    /// One row of the merge table: a job PR artifact, its approval state,
    /// and any merge-run outcome.
    struct MergeRow: Identifiable {
        let artifact: Artifact
        let repo: RepoRef
        let number: Int
        let approved: Bool
        let result: RepoResult?
        var id: String { artifact.repo }
        // Non-optional status ordinal for table sorting; rows with no run yet
        // sort last.
        var completeOrder: Int { result?.status.sortOrder ?? Int.max }
    }

    var mergeRows: [MergeRow] {
        let results = resultsByPhase[.merge] ?? []
        // One row per repo, latest artifact wins — stale registry entries
        // from an earlier session must not produce duplicate rows.
        var byRepo: [String: MergeRow] = [:]
        var order: [String] = []
        for artifact in artifacts where artifact.kind == .pullRequest {
            guard let number = Int(artifact.name.dropFirst()) else { continue }
            if byRepo[artifact.repo] == nil { order.append(artifact.repo) }
            let result = results.first { $0.id == artifact.repo }
            byRepo[artifact.repo] = MergeRow(
                artifact: artifact,
                repo: result?.repo ?? RepoRef(fullName: artifact.repo),
                number: number,
                approved: approvals.contains {
                    $0.repo == artifact.repo && $0.prNumber == number
                },
                result: result)
        }
        return order.compactMap { byRepo[$0] }
    }

    /// Approve every job PR that isn't yet approved, capturing each current
    /// head SHA.
    func approveAll() {
        let pending = mergeRows.filter { !$0.approved }
        guard !pending.isEmpty else { return }
        let client = githubClient()
        // Just the Sendable scalars each fetch needs — MergeRow isn't Sendable.
        let targets = pending.map { (repo: $0.artifact.repo, number: $0.number) }
        let total = targets.count
        statusLine = "Approving 0 of \(total)…"
        Task {
            var added = 0
            var done = 0
            var failures: [(number: Int, repo: String, error: String)] = []
            // Each PR's getPR is an independent live round-trip that pins the
            // current head SHA (the SHA-pinned merge precondition). Fan them
            // out under a bounded group so a long merge queue doesn't approve
            // one PR at a time; the API cost is unchanged. The approvals/
            // statusLine mutations stay on the MainActor (this Task inherits
            // AppModel's isolation); the child tasks touch only Sendable values.
            let maxConcurrent = min(6, total)
            await withTaskGroup(of: (repo: String, number: Int, headSha: String?, error: String?).self) { group in
                var next = 0
                func addTask(_ index: Int) {
                    let target = targets[index]
                    group.addTask {
                        do {
                            let pr = try await client.getPR(repo: target.repo, number: target.number)
                            return (target.repo, target.number, pr.headSha, nil)
                        } catch {
                            return (target.repo, target.number, nil, error.localizedDescription)
                        }
                    }
                }
                while next < maxConcurrent { addTask(next); next += 1 }
                for await fetched in group {
                    done += 1
                    if let headSha = fetched.headSha {
                        // Skip if a concurrent toggleApproval already approved it.
                        if !approvals.contains(where: { $0.repo == fetched.repo && $0.prNumber == fetched.number }) {
                            approvals.append(Approval(repo: fetched.repo,
                                                      prNumber: fetched.number, headSha: headSha))
                            added += 1
                        }
                    } else {
                        failures.append((fetched.number, fetched.repo, fetched.error ?? "unknown error"))
                    }
                    if next < total { addTask(next); next += 1 }
                    statusLine = "Approving \(done) of \(total)…"
                }
            }
            // Failures are accumulated, not left in a transient statusLine that
            // the progress line clobbers — compose one final summary so
            // silently-skipped PRs are surfaced regardless of completion order.
            if let firstFailure = failures.first {
                statusLine = added > 0
                    ? "Approved \(added) PR(s); \(failures.count) could not be approved (e.g. #\(firstFailure.number) in \(firstFailure.repo): \(firstFailure.error))"
                    : "Could not approve \(failures.count) PR(s) — none approved (e.g. #\(firstFailure.number) in \(firstFailure.repo): \(firstFailure.error))"
            } else if added > 0 {
                statusLine = "Approved \(added) PR(s) — merging requires each head to still match"
            }
            if added > 0 { saveNow() }
        }
    }

    func clearApprovals() {
        guard !approvals.isEmpty else { return }
        approvals.removeAll()
        statusLine = "All approvals withdrawn"
        saveNow()
    }

    /// Approve (capturing the current head SHA) or withdraw approval.
    func toggleApproval(repo: String, prNumber: Int) {
        if let index = approvals.firstIndex(where: { $0.repo == repo && $0.prNumber == prNumber }) {
            approvals.remove(at: index)
            statusLine = "Approval withdrawn for PR #\(prNumber) in \(repo)"
            saveNow()
            return
        }
        let client = githubClient()
        Task {
            do {
                let pr = try await client.getPR(repo: repo, number: prNumber)
                approvals.append(Approval(repo: repo, prNumber: prNumber, headSha: pr.headSha))
                statusLine = "Approved PR #\(prNumber) in \(repo) at \(String(pr.headSha.prefix(12))) — merging requires the head to still match"
                saveNow()
            } catch {
                statusLine = "Could not approve PR #\(prNumber): \(error.localizedDescription)"
            }
        }
    }

    var updateRows: [UpdateRow] {
        let checks = resultsByPhase[.check] ?? []
        let updates = resultsByPhase[.update] ?? []
        var updatesByID = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0) })
        var rows: [UpdateRow] = checks.map { check in
            let update = updatesByID.removeValue(forKey: check.id)
            return UpdateRow(repo: update?.repo ?? check.repo, check: check, update: update)
        }
        // Repos only the update run touched (e.g. a full scan with no carried
        // check results), in run order.
        for result in updates where updatesByID[result.id] != nil {
            rows.append(UpdateRow(repo: result.repo, check: nil, update: result))
        }
        return rows
    }

    /// Row count for the status footer — the update table includes carried
    /// check rows, and the merge table shows registry PRs.
    var visibleRowCount: Int {
        switch phase {
        case .check: return results.count
        case .update: return updateRows.count
        case .merge: return mergeRows.count
        }
    }

    /// Switching between fixture data and live GitHub is switching WORLDS:
    /// results, plans, artifacts, approvals, and carried state from the old
    /// world are meaningless in the new one (fixture PR receipts point at
    /// nothing real, and vice versa). Workspaces — prompts, scripts, params —
    /// survive; they are world-independent.
    func dataSourceChanged() {
        guard !running else { return }
        resultsByPhase = [:]
        ranScriptByPhase = [:]
        ranParamsByPhase = [:]
        plannedActions = [:]
        plannedActionsPhase = nil
        artifacts = []
        approvals = []
        appliedPlan = [:]
        jobState = [:]
        selectedRepo = nil
        canaryRepo = ""
        quotaText = nil
        quotaResetText = nil
        quotaPauseText = nil
        quotaPauseIsHeld = false
        logs = []
        auditEvents = []
        auditTrail = []
        writeArmed = false
        applyTargetsByPhase = [:]
        statusLine = settings.useFixtureGitHub
            ? "Switched to fixture data — workflow state cleared, scripts kept"
            : "Switched to LIVE GitHub — workflow state cleared, scripts kept"
        saveNow()
    }

    // MARK: New job (File > New Job…, ⌘N)

    /// Drives the confirmation alert — New Job always confirms before
    /// discarding, since it wipes every phase's workspace and history.
    var showNewJobConfirmation = false
    /// Drives the refusal alert when the artifact registry is non-empty.
    var showNewJobBlocked = false

    func requestNewJob() {
        guard !running, !generating, !validating else { return }
        // Wiping the registry would orphan the branches/PRs this job
        // created: the registry is the only authority merge/cancel has, so
        // nothing could ever touch them again. Refuse, pointing at the
        // merge/cancel path, rather than confirm-through.
        if !artifacts.isEmpty {
            showNewJobBlocked = true
        } else {
            showNewJobConfirmation = true
        }
    }

    /// Discard the entire job — all three phase workspaces, results, plans,
    /// logs, the audit trail, and carried job state — leaving an empty
    /// workspace. (First launch loads the golden recipe for discoverability;
    /// New Job deliberately does not — the library is one click away, and a
    /// "new" workspace with a pre-filled script reads as "didn't clear".)
    /// Settings and credentials survive. Reached only via requestNewJob's
    /// confirmation.
    func startNewJob() {
        guard !running, !generating, artifacts.isEmpty else { return }
        wipeJobState()
        statusLine = "New job — describe what to find, or load a recipe"
        saveNow()
    }

    /// Force-discard the job even when the artifact registry is non-empty —
    /// the escape hatch from requestNewJob's refusal. This ABANDONS tracking
    /// of anything still live on the remote: the registry is the only
    /// authority merge/cancel has, so any branch or PR this job created and
    /// did not merge/cancel becomes orphaned (it stays on GitHub; this app can
    /// never touch it again). The audit trail keeps a record of what was
    /// abandoned. Reached only via the showNewJobBlocked alert's destructive
    /// button — the last resort when merge/cancel can't reconcile a partial
    /// failure. Also clears the on-disk snapshot so a relaunch can't restore
    /// the stranded receipts.
    func discardJobAndReset() {
        guard !running, !generating, !validating else { return }
        // Name the receipts being abandoned before wiping them — this record
        // is the only trace that survives the reset.
        let abandoned = artifacts
            .map { "\($0.kind.rawValue) \($0.name) in \($0.repo)" }
            .sorted()
        wipeJobState()
        // The audit trail is the deliberate exception to the wipe: the
        // abandonment record must survive a force-reset.
        if !abandoned.isEmpty {
            auditTrail = [AuditEvent(kind: "reset", repo: nil,
                                     detail: "registry force-reset — abandoned \(abandoned.count) artifact(s): \(abandoned.joined(separator: ", "))")]
        }
        // Nuke the persisted snapshot too: a relaunch reading the old file
        // would restore exactly the stranded receipts we just abandoned.
        store.clear()
        statusLine = abandoned.isEmpty
            ? "Registry reset — describe what to find, or load a recipe"
            : "Registry reset — \(abandoned.count) remote artifact(s) abandoned (see audit trail)"
        saveNow()
    }

    /// The shared in-memory wipe behind both startNewJob and the force-reset:
    /// every phase workspace, results, plans, logs, audit trail, carried job
    /// state, AND the artifact registry (approvals/appliedPlan included). For
    /// startNewJob the registry is already empty, so clearing it is a no-op;
    /// for discardJobAndReset it is the whole point. Does not touch the status
    /// line, persistence, or settings — callers own those.
    private func wipeJobState() {
        phase = .check
        prompt = ""
        scriptText = ""
        paramsDraft = [:]
        prTitle = ""
        prBody = ""
        canaryRepo = ""
        jobState = [:]
        promptsByPhase = [:]
        scriptsByPhase = [:]
        paramsByPhase = [:]
        diagnostics = []
        resultsByPhase = [:]
        ranScriptByPhase = [:]
        ranParamsByPhase = [:]
        declaredParamsByPhase = [:]
        logs = []
        auditEvents = []
        auditTrail = []
        plannedActions = [:]
        plannedActionsPhase = nil
        artifacts = []
        approvals = []
        appliedPlan = [:]
        selectedRepo = nil
        writeArmed = false
        applyTargetsByPhase = [:]
        quotaText = nil
        quotaResetText = nil
        quotaPauseText = nil
        quotaPauseIsHeld = false
    }

    func clearResults() {
        resultsByPhase[phase] = []
        ranScriptByPhase[phase] = nil
        ranParamsByPhase[phase] = nil
        if plannedActionsPhase == phase {
            plannedActions = [:]
            plannedActionsPhase = nil
            applyTargetsByPhase[phase] = nil
        }
        selectedRepo = nil
        statusLine = "Results cleared"
    }

    func useAsCanary(_ repoID: String) {
        canaryRepo = repoID
        setPhase(.update)
        selectedRepo = repoID
        statusLine = "Canary set — update runs are confined to \(repoID)"
    }

    // MARK: Flow bar badges — what each stage has produced

    var matchedCount: Int {
        (resultsByPhase[.check] ?? []).filter { $0.status == .verifiedMatch }.count
    }
    var plannedRepoCount: Int {
        plannedActionsPhase == .update ? plannedActions.count : 0
    }
    var registryPRCount: Int { mergeRows.count }

    /// Determinate run progress as (processed, total) when the current run has
    /// a known denominator, else nil (→ the indeterminate spinner). A scan
    /// (Find, or an Update that re-enumerated the org) gets it from the
    /// streamed candidate rows; Update/Merge runs that work a known set get it
    /// from the matched/selected/registry counts.
    var runProgress: (processed: Int, total: Int)? {
        guard running else { return nil }
        if runHadCandidates {
            let total = results.count
            guard total > 0 else { return nil }
            return (results.filter { $0.status != .candidate }.count, total)
        }
        let total: Int
        switch phase {
        case .update: total = currentRunIsArmed ? applyTargets.count : matchedCount
        case .merge: total = mergeRows.count
        case .check: return nil
        }
        guard total > 0 else { return nil }
        return (min(results.count, total), total)
    }

    func setPhase(_ newPhase: JobPhase) {
        guard newPhase != phase, !running, !generating else { return }
        // Each phase is a separate workspace: prompt, script, and params swap
        // together. An update workspace starts empty rather than inheriting
        // the check script.
        stashWorkspace()
        phase = newPhase
        restoreWorkspace()
        writeArmed = false
        // Re-default the apply selection for the phase we're entering: a
        // restored/existing plan stays applyable (canary-first in update, all
        // planned in merge), and a phase with no plan resolves to empty.
        refreshApplyTargets()
        switch newPhase {
        case .check:
            statusLine = "Find phase — prompts generate read-only search scripts"
        case .update:
            statusLine = "Update phase — prompts generate dry-run update scripts (nothing reaches GitHub)"
        case .merge:
            statusLine = "Complete phase — approve job PRs in the table, then dry-run a script that acts only on this job's PRs and branches"
        }
    }

    private func stashWorkspace() {
        promptsByPhase[phase] = prompt
        scriptsByPhase[phase] = scriptText
        paramsByPhase[phase] = paramsDraft
    }

    private func restoreWorkspace() {
        prompt = promptsByPhase[phase] ?? ""
        scriptText = scriptsByPhase[phase] ?? ""
        paramsDraft = paramsByPhase[phase] ?? [:]
        diagnostics = []
    }

    func loadRecipe(_ recipe: Recipe) {
        guard let source = recipe.source, !running, !generating else { return }
        if recipe.phase != phase {
            stashWorkspace()
            phase = recipe.phase
        }
        writeArmed = false
        applyTargetsByPhase[phase] = nil
        scriptText = source
        prompt = recipe.prompt
        promptsByPhase[recipe.phase] = recipe.prompt
        scriptsByPhase[recipe.phase] = source
        // The params belong to the script: a replaced script means a fresh
        // draft (and fresh declared defaults), not the previous script's
        // values lingering in the bar.
        paramsDraft = [:]
        paramsByPhase[recipe.phase] = [:]
        declaredParamsByPhase[recipe.phase] = nil
        diagnostics = []
        statusLine = "Loaded \"\(recipe.title)\""
        // Validate right away so the param bar repopulates from the recipe's
        // meta.params without waiting for a manual Check. Any in-flight
        // validation of the replaced script must fully drain first (its
        // results are discarded by the stale-source guard) — validate()
        // would otherwise JOIN it and return the old script's result.
        Task { [weak self] in
            while let task = self?.validationTask {
                _ = await task.value
                await Task.yield()
            }
            await self?.validate()
        }
    }

    func loadRecipe(named name: String) {
        guard let recipe = RecipeCatalog.recipe(id: name) else { return }
        loadRecipe(recipe)
    }

    // MARK: User recipes (saved from the workspace, file-backed)

    @ObservationIgnored private let recipeStore = UserRecipeStore()
    private(set) var userRecipes: [UserRecipe] = []

    /// Drives the save-as-recipe name prompt; recipeNameDraft backs the
    /// rename prompt too.
    var showSaveRecipePrompt = false
    var recipeNameDraft = ""
    var renamingRecipe: UserRecipe?
    var deletingRecipe: UserRecipe?

    func requestSaveRecipe() {
        guard !scriptText.isEmpty else {
            statusLine = "Nothing to save — the editor is empty"
            return
        }
        recipeNameDraft = ""
        showSaveRecipePrompt = true
    }

    /// Capture the current workspace — prompt, script, phase — under the
    /// drafted name.
    func saveCurrentAsRecipe() {
        let title = recipeNameDraft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !scriptText.isEmpty else { return }
        do {
            try recipeStore.save(UserRecipe(title: title, prompt: prompt,
                                            phase: phase, source: scriptText))
            userRecipes = recipeStore.load()
            statusLine = "Saved recipe \"\(title)\""
        } catch {
            statusLine = "Could not save recipe: \(error.localizedDescription)"
        }
    }

    func renameRecipe(_ recipe: UserRecipe) {
        let title = recipeNameDraft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != recipe.title else { return }
        var renamed = recipe
        renamed.title = title
        do {
            try recipeStore.save(renamed)
            userRecipes = recipeStore.load()
            statusLine = "Renamed recipe to \"\(title)\""
        } catch {
            statusLine = "Could not rename recipe: \(error.localizedDescription)"
        }
    }

    func deleteRecipe(_ recipe: UserRecipe) {
        do {
            try recipeStore.delete(id: recipe.id)
            userRecipes = recipeStore.load()
            statusLine = "Deleted recipe \"\(recipe.title)\""
        } catch {
            statusLine = "Could not delete recipe: \(error.localizedDescription)"
        }
    }

    func loadGoldenRecipe() {
        loadRecipe(named: "find_file_missing_string")
    }

    // MARK: Client selection

    /// ONE fixture instance per app session: armed-run writes (branches, PRs)
    /// must survive into the merge phase or the loop can't be rehearsed —
    /// a fresh demo() per call silently discarded them.
    @ObservationIgnored private lazy var fixtureClient = FixtureGitHubClient.demo()

    func githubClient() -> GitHubClient {
        if settings.useFixtureGitHub { return fixtureClient }
        let credentials = self.credentials
        return LiveGitHubClient(apiHost: settings.apiHost,
                                tokenProvider: { credentials.read(.githubToken) },
                                session: githubSession,
                                rateLimit: rateLimit,
                                retry: retryMonitor,
                                writePacer: writePacer,
                                etagCache: etagCache)
    }

    /// Tear down the GitHub connection pool — the escape hatch for a wedged
    /// connection (#14). The old session (and its stale HTTP/2 connections) is
    /// invalidated; the next githubClient() builds on a fresh one.
    func resetGitHubSession() {
        githubSession.invalidateAndCancel()
        githubSession = LiveGitHubClient.makeSession()
        statusLine = "GitHub connection reset"
    }

    private func refreshQuota() {
        quotaText = settings.useFixtureGitHub ? nil : rateLimit.display
        // Only when the budget is running out — a reset countdown next to a
        // healthy quota is just noise; next to an exhausted one it's the answer.
        quotaResetText = (settings.useFixtureGitHub || !rateLimit.isLow) ? nil : rateLimit.resetDisplay
    }

    private func refreshRetry() {
        retryText = settings.useFixtureGitHub ? nil : retryMonitor.display
    }

    /// Reflect the quota gate's pause state into the UI, and notify a
    /// walked-away user once when a run holds for a long (beyond-cap) reset.
    private func refreshPauseState() {
        guard let pause = quotaGate.pauseState else {
            quotaPauseText = nil
            quotaPauseIsHeld = false
            return
        }
        let clock = pause.resumeAt.formatted(date: .omitted, time: .shortened)
        let mins = max(0, Int((pause.resumeAt.timeIntervalSinceNow / 60).rounded(.up)))
        if pause.heldForManual {
            quotaPauseText = "Paused — GitHub quota exhausted; resets \(clock) (~\(mins) min). Resume now or Stop."
            if !notifiedHeldPause {
                notifiedHeldPause = true
                NotificationService.notifyRunComplete(
                    title: "BulkGitHub — paused on GitHub quota",
                    body: "Quota resets at \(clock) (~\(mins) min). Resume now, or cancel the run.")
            }
        } else {
            quotaPauseText = "Paused — GitHub quota exhausted; resuming \(clock) (~\(mins) min)."
        }
        quotaPauseIsHeld = pause.heldForManual
    }

    /// Manual "Resume now" — skip the remaining quota wait and try again.
    func resumeQuotaWait() {
        quotaGate.resumeNow()
    }

    /// Notify on completion when the run hit retries or ran long — but only if
    /// the user has walked away (handled in NotificationService). Skips cancels.
    private func notifyIfWalkedAway(outcome: RunOutcome, phase: JobPhase, retried: Bool) {
        guard outcome.status != .cancelled, retried || outcome.duration >= 60 else { return }
        NotificationService.notifyRunComplete(
            title: "BulkGitHub — \(phase.displayName) \(outcome.status.label)",
            body: statusLine)
    }

    func llmClient() -> LLMClient {
        if settings.useMockLLM { return MockLLMClient() }
        let credentials = self.credentials
        return AnthropicClient(model: settings.aiModel,
                               keyProvider: { credentials.read(.anthropicAPIKey) })
    }

    // MARK: Actions

    func generate() {
        guard !generating, !prompt.isEmpty else { return }
        generating = true
        statusLine = "Requesting script… (model thinking)"
        let client = llmClient()
        let context = ScriptGenerationContext(organisation: settings.organisation, phase: phase)
        var promptText = prompt
        if phase == .update, !prTitle.isEmpty {
            promptText += "\n\nUse exactly this pull request title: \"\(prTitle)\""
        }
        if phase == .update, !prBody.isEmpty {
            promptText += "\n\nUse exactly this pull request description: \"\(prBody)\""
        }
        let previousScript = scriptText
        Task {
            // Stream the raw response, painting the in-progress script into
            // the editor as it is written; parse the assembled text at the end.
            var raw = ""
            do {
                for try await event in client.streamScript(prompt: promptText, context: context) {
                    guard case .delta(let chunk) = event else { continue }
                    raw += chunk
                    let live = PromptLibrary.liveScript(fromPartial: raw)
                    if !live.isEmpty { scriptText = live }
                    statusLine = "Writing script… \(raw.count) characters"
                }
                switch PromptLibrary.parseGeneration(from: raw) {
                case .script(let script) where !script.isEmpty:
                    scriptText = script
                    // A generated script replaces the old one wholesale, so
                    // its declared params must win — stale draft values from
                    // the previous script would override what the model just
                    // wrote (e.g. values it patched in from the prompt).
                    paramsDraft = [:]
                    declaredParamsByPhase[phase] = nil
                    statusLine = "Script generated — review before running"
                    generating = false
                    await validate()
                case .script:
                    scriptText = previousScript
                    statusLine = "Generation produced no script"
                    generating = false
                case .capabilityGap(let report):
                    scriptText = capabilityGapScript(report)
                    surfaceCapabilityGap(report)
                    generating = false
                }
            } catch LLMClientError.capabilityGap(let report) {
                scriptText = capabilityGapScript(report)
                surfaceCapabilityGap(report)
                generating = false
            } catch {
                scriptText = previousScript
                statusLine = "Generation failed: \(error.localizedDescription)"
                generating = false
            }
        }
    }

    private func surfaceCapabilityGap(_ report: String) {
        statusLine = "Capability gap — the model needs host APIs we don't offer (details in console)"
        logs.append("◆ The model reports this request needs capabilities the host API does not provide:")
        for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
            logs.append("  " + String(line))
        }
    }

    /// Renders a capability-gap report as a commented-out script so the error
    /// stays visible in the editor — where the user is looking — instead of
    /// being lost under a restored previous script. It is intentionally not
    /// runnable; the user revises the prompt and regenerates.
    private func capabilityGapScript(_ report: String) -> String {
        var lines = ["// ⚠︎ Capability gap — this request can't be fulfilled with the host APIs",
                     "// available. Revise the prompt and Generate again.",
                     "//"]
        for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(line.isEmpty ? "//" : "// " + String(line))
        }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    func validate() async -> ValidatedScript? {
        // Join an in-flight validation (e.g. the auto-validate right after
        // generation) instead of bailing with nil — the silent nil made Run
        // a no-op the first time after regenerating a script.
        if let task = validationTask { return await task.value }
        let task = Task { await performValidation() }
        validationTask = task
        let result = await task.value
        validationTask = nil
        return result
    }

    private func performValidation() async -> ValidatedScript? {
        validating = true
        defer { validating = false }
        statusLine = typeCheckingAvailable ? "Type-checking against bulkgh.d.ts…" : "Checking…"
        let source = scriptText
        let pipeline = self.pipeline
        do {
            let validated = try await Task.detached(priority: .userInitiated) {
                try pipeline.validate(source: source)
            }.value
            // The editor moved on mid-validation (recipe load, regenerate):
            // this result describes a script that is no longer on screen.
            guard source == scriptText else { return nil }
            diagnostics = validated.diagnostics
            var merged = validated.meta.params
            for (key, value) in paramsDraft where merged[key] != nil {
                merged[key] = value
            }
            paramsDraft = merged
            // A script declaring a different phase moves there WITH the
            // current buffer (no workspace swap): the script, prompt, and
            // params on screen belong to the declared phase now.
            phase = validated.meta.phase
            declaredParamsByPhase[validated.meta.phase] = validated.meta.params
            // Two-way sync with the explicit PR title/description fields: an
            // explicit value wins; otherwise the script's generated one shows.
            if !prTitle.isEmpty {
                if paramsDraft["prTitle"] != nil { paramsDraft["prTitle"] = prTitle }
            } else if let generated = paramsDraft["prTitle"] {
                prTitle = generated
            }
            if !prBody.isEmpty {
                if paramsDraft["prBody"] != nil { paramsDraft["prBody"] = prBody }
            } else if let generated = paramsDraft["prBody"] {
                prBody = generated
            }
            // Mandatory-but-never-blank: the update-phase PR fields are required,
            // so if the script declared no prTitle/prBody param and the field is
            // still empty, seed a sensible default the user can edit (the script's
            // title; a generic body). The host override then carries it onto the PR.
            if validated.meta.phase == .update {
                if prTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    prTitle = validated.meta.title
                }
                if prBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    prBody = "Generated by BulkGitHub. Review the diff before merging."
                }
            }
            statusLine = "Valid — \(validated.meta.title)"
            return validated
        } catch let error as ValidationError {
            guard source == scriptText else { return nil }
            diagnostics = error.diagnostics
            statusLine = error.errorDescription ?? "Validation failed"
            return nil
        } catch {
            guard source == scriptText else { return nil }
            statusLine = "Validation failed: \(error.localizedDescription)"
            return nil
        }
    }

    func run() {
        guard !running, !generating else { return }
        runTask = Task { await runInternal() }
    }

    /// Re-run the reviewed dry-run plan with writes ARMED for the selected
    /// repos. The engine enforces plan conformance and the drift guard;
    /// in live mode this REALLY writes to GitHub — the Apply sheet is the
    /// explicit confirmation step.
    func applyPlan(to repoIDs: Set<String>) {
        guard !running, !generating, phase == .update || phase == .merge else { return }
        guard !repoIDs.isEmpty, !plannedActions.isEmpty,
              plannedActionsPhase == phase else { return }
        runTask = Task { await runInternal(writeMode: .armed, armedTargets: repoIDs) }
    }

    private func runInternal(writeMode: EngineConfiguration.WriteMode = .dryRun,
                             armedTargets: Set<String> = []) async {
        guard let validated = await validate() else { return }
        running = true
        runHadCandidates = false
        currentRunIsArmed = (writeMode == .armed)
        let retryBaseline = retryMonitor.totalRetries
        NotificationService.requestAuthorizationIfNeeded()
        // Poll the retry monitor while the run is live: the footer refresh is
        // otherwise pumped by .audit events, which only fire on SUCCESS — a run
        // stalled in backoff would never update the footer without this.
        quotaGate.reset()
        notifiedHeldPause = false
        let retryPoll = Task { @MainActor [weak self] in
            while self?.running == true {
                self?.refreshRetry()
                self?.refreshPauseState()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            self?.retryText = nil
            self?.quotaPauseText = nil
            self?.quotaPauseIsHeld = false
        }
        defer {
            retryPoll.cancel()
            retryText = nil
            quotaPauseText = nil
            quotaPauseIsHeld = false
            running = false
            currentRunIsArmed = false
            // Write mode is per-run: it never survives the run that used it
            // (or a dry run started while it was somehow on).
            writeArmed = false
        }
        let runPhase = validated.meta.phase
        let runScript = scriptText
        // A fresh check starts a fresh funnel: the canary, the update
        // results, and the dry-run plan were all derived from the check
        // results this run replaces — carrying them forward made the update
        // table open on outdated statuses (and a misleading stale banner).
        // The update SCRIPT survives; it is reusable against the new results.
        // The artifact registry is never cleared — those are receipts for
        // things armed runs really created.
        if runPhase == .check {
            canaryRepo = ""
            resultsByPhase[.update] = []
            ranScriptByPhase[.update] = nil
            ranParamsByPhase[.update] = nil
            plannedActions = [:]
            plannedActionsPhase = nil
        }
        runGeneration += 1
        let generation = runGeneration
        resultsByPhase[runPhase] = []
        logs = []
        auditEvents = []
        // The reviewed plan survives an armed run — it is the reference the
        // engine checked the writes against.
        if runPhase != .check, writeMode == .dryRun {
            plannedActions = [:]
            plannedActionsPhase = nil
        }
        statusLine = writeMode == .armed ? "ARMED — applying the reviewed plan…" : "Running…"
        let params = effectiveParams(for: runPhase)
        var configuration = EngineConfiguration(settings: settings)
        if runPhase == .update {
            // Host-authoritative: the user's reviewed PR fields drive every
            // created PR. Set on BOTH dry-run and armed so the recorded plan
            // and the armed conformance check agree.
            configuration.prTitleOverride = prTitle.isEmpty ? nil : prTitle
            configuration.prBodyOverride = prBody.isEmpty ? nil : prBody
        }
        if writeMode == .armed {
            configuration.writeMode = .armed
            configuration.targetRepos = armedTargets
            configuration.referencePlan = plannedActions
        } else {
            let canary = canaryRepo.trimmingCharacters(in: .whitespaces)
            if runPhase == .update, !canary.isEmpty {
                let fullName = canary.contains("/") ? canary : "\(settings.organisation)/\(canary)"
                configuration.targetRepos = [fullName]
            } else if runPhase == .update {
                // Carry the Find selection forward: scope a dry-run update to the
                // repos Find matched, so repos Find SKIPPED don't reappear in the
                // Update run (and it doesn't waste API calls re-examining them).
                // Host-authoritative — a re-enumerating script only sees matches.
                // Empty (no Find run / nothing matched) = no scope, enumerate the
                // org as before. A canary still overrides (handled above).
                let findMatches = Set((resultsByPhase[.check] ?? [])
                    .filter { $0.status == .verifiedMatch }
                    .map(\.repo.fullName))
                if !findMatches.isEmpty { configuration.targetRepos = findMatches }
            }
        }
        if runPhase == .merge || writeMode == .armed {
            // The job's receipts: merge scripts are scoped to them, and
            // armed update runs use them to RESUME safely onto branches/PRs
            // this job created earlier (never onto anyone else's).
            configuration.artifactRegistry = artifacts
        }
        if runPhase == .merge {
            configuration.approvals = approvals
        }
        let outcome = await engine.run(javaScript: validated.javaScript,
                                       phase: runPhase,
                                       params: params,
                                       github: githubClient(),
                                       // Fixture runs never touch the live quota
                                       // monitor — don't let a prior live run's
                                       // low reading pause them.
                                       quotaGate: settings.useFixtureGitHub ? nil : quotaGate,
                                       organisation: settings.organisation,
                                       configuration: configuration,
                                       initialState: jobState) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.runGeneration == generation else { return }
                self.handle(event, phase: runPhase)
            }
        }
        // Retire stragglers before installing the final snapshot — a late
        // event hopping onto the main actor afterwards would duplicate rows
        // or log lines.
        runGeneration += 1
        resultsByPhase[runPhase] = outcome.results
        ranScriptByPhase[runPhase] = runScript
        ranParamsByPhase[runPhase] = params
        logs = outcome.logs
        auditEvents = outcome.auditEvents
        // The cumulative trail: boundary event, then the run's events.
        let mode = writeMode == .armed ? "ARMED"
            : (runPhase == .check ? "read-only" : "dry run")
        auditTrail.append(AuditEvent(kind: "run", repo: nil,
                                     detail: "\(runPhase.displayName.lowercased()) (\(mode), \(settings.useFixtureGitHub ? "fixture" : "live")) — \(outcome.status.label)"))
        auditTrail.append(contentsOf: outcome.auditEvents)
        if auditTrail.count > 5000 {
            auditTrail.removeFirst(auditTrail.count - 5000)
        }
        if runPhase != .check, writeMode == .dryRun {
            plannedActions = outcome.plannedActions
            plannedActionsPhase = outcome.plannedActions.isEmpty ? nil : runPhase
            // A fresh plan resets this phase's selection to the canary-first
            // default (force), so flipping to Write shows the right rows
            // checked. Phase-entry refreshes (setPhase/init) do NOT force, so
            // they preserve an intentional deselection.
            refreshApplyTargets(force: true)
        }
        // Replace rather than accumulate: re-applying after a halt (or in a
        // fresh fixture session) must not leave duplicate receipts for the
        // same branch or PR.
        for artifact in outcome.artifacts {
            artifacts.removeAll {
                $0.kind == artifact.kind && $0.repo == artifact.repo && $0.name == artifact.name
            }
            artifacts.append(artifact)
        }
        // The receipts behind each PR: what the armed update actually wrote,
        // per repo — shown in the merge phase as "what this PR changes".
        // Fresh PRs also supersede any previous merge-phase outcomes: an old
        // "merged" badge must not attach to a new PR.
        if writeMode == .armed, runPhase == .update {
            for result in outcome.results where result.status == .prRaised {
                appliedPlan[result.id] = plannedActions[result.id]
            }
            resultsByPhase[.merge] = []
            ranScriptByPhase[.merge] = nil
            ranParamsByPhase[.merge] = nil
        }
        // A merged or cancelled repo's artifacts are consumed: its PR is no
        // longer open and its branch is gone — drop them (and their
        // approvals and applied plan) from the registry. The audit trail
        // keeps the history.
        if writeMode == .armed, runPhase == .merge {
            let consumed = Set(outcome.results
                .filter { [.merged, .cancelled].contains($0.status) }
                .map(\.id))
            if !consumed.isEmpty {
                artifacts.removeAll { consumed.contains($0.repo) }
                approvals.removeAll { consumed.contains($0.repo) }
                for repo in consumed { appliedPlan.removeValue(forKey: repo) }
            }
            // Orphan branches the run deleted (no PR, so their repo never
            // reached merged/cancelled above): drop just those branch
            // artifacts so the registry can finally empty.
            for branch in outcome.consumedBranches {
                artifacts.removeAll {
                    $0.kind == branch.kind && $0.repo == branch.repo && $0.name == branch.name
                }
            }
        }
        if !outcome.state.isEmpty {
            jobState.merge(outcome.state) { _, new in new }
        }
        refreshQuota()
        if let quotaText {
            var line = "◆ GitHub \(quotaText) requests remaining"
            if let quotaResetText { line += " — \(quotaResetText)" }
            logs.append(line)
        }
        if writeMode == .armed {
            let acted = outcome.results.filter {
                [.prRaised, .merged, .cancelled].contains($0.status)
            }
            // Terminal metadata writes (e.g. custom properties): applied directly,
            // no branch/PR/registry entry — so there is nothing to merge afterwards.
            let updated = outcome.results.filter { $0.status == .updated }
            let halted = outcome.results.filter {
                [.conflicted, .branchExists, .prExists, .blocked].contains($0.status)
            }
            if selectedRepo == nil { selectedRepo = acted.first?.id ?? updated.first?.id }
            var parts: [String] = []
            if !acted.isEmpty {
                parts.append("\(acted.count) \(runPhase == .merge ? "PR(s) merged or closed" : "PR(s) raised")")
            }
            if !updated.isEmpty {
                parts.append("\(updated.count) repo(s) updated directly — applied, no PR to merge")
            }
            if parts.isEmpty { parts.append("nothing written") }
            var summary = "ARMED run \(outcome.status.label) — " + parts.joined(separator: ", ")
            if !halted.isEmpty { summary += ", \(halted.count) halted (see results)" }
            statusLine = summary
        } else {
            let plannedRepos = outcome.results.filter { $0.status == .planned }
            if !plannedRepos.isEmpty {
                // Keep the user's selection (e.g. the canary they were
                // inspecting); only auto-select when nothing was chosen.
                if selectedRepo == nil { selectedRepo = plannedRepos.first?.id }
                statusLine = "Run \(outcome.status.label) — \(plannedRepos.count) repo(s) planned; dry-run diffs in the right panel"
            } else {
                statusLine = "Run \(outcome.status.label)"
            }
        }
        notifyIfWalkedAway(outcome: outcome, phase: runPhase,
                           retried: retryMonitor.totalRetries > retryBaseline)
        saveNow()
    }

    func cancel() {
        runTask?.cancel()
        statusLine = "Cancelling…"
    }

    private func handle(_ event: RunEvent, phase runPhase: JobPhase) {
        switch event {
        case .log(let line):
            logs.append(line)
        case .progress(let line):
            logs.append("▸ \(line)")
        case .repo(let result):
            if result.status == .candidate { runHadCandidates = true }
            var rows = resultsByPhase[runPhase] ?? []
            if let index = rows.firstIndex(where: { $0.id == result.id }) {
                rows[index] = result
            } else {
                rows.append(result)
            }
            resultsByPhase[runPhase] = rows
        case .plan(let repo, let actions):
            // Stream the dry-run plan into the live view: PlanView renders
            // activePlan the instant it is non-empty. Dry runs only — an armed
            // run is conforming to the already-reviewed plan and must not
            // clobber it, and a check run never plans.
            guard !currentRunIsArmed, runPhase != .check else { break }
            plannedActions[repo] = actions
            plannedActionsPhase = runPhase
        case .audit(let event):
            auditEvents.append(event)
            refreshQuota()
        }
    }

    // MARK: Persistence

    func saveNow() {
        stashWorkspace()
        var job = Job(prompt: prompt, phase: phase)
        job.scriptSource = scriptText
        job.params = paramsDraft
        job.results = results
        job.resultsByPhase = Self.rawKeyed(resultsByPhase)
        job.ranScriptByPhase = Self.rawKeyed(ranScriptByPhase)
        job.ranParamsByPhase = Self.rawKeyed(ranParamsByPhase)
        job.declaredParamsByPhase = Self.rawKeyed(declaredParamsByPhase)
        job.scriptsByPhase = Self.rawKeyed(scriptsByPhase)
        job.paramsByPhase = Self.rawKeyed(paramsByPhase)
        job.logs = logs
        job.auditEvents = auditEvents
        job.auditTrail = auditTrail
        job.plannedActions = plannedActions
        job.planPhase = plannedActionsPhase?.rawValue
        job.state = jobState
        job.prTitle = prTitle
        job.prBody = prBody
        job.canaryRepo = canaryRepo
        job.artifacts = artifacts
        job.approvals = approvals
        job.appliedPlans = appliedPlan
        job.promptsByPhase = Self.rawKeyed(promptsByPhase)
        job.lastRunStatus = statusLine
        try? store.save(AppStateSnapshot(settings: settings, job: job))
    }
}
