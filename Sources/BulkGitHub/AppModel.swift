import Foundation
import Observation
import BulkGitHubKit

@MainActor
@Observable
final class AppModel {
    var settings = AppSettings()
    var prompt: String = ""
    var scriptText: String = ""
    var paramsDraft: [String: String] = [:]
    var diagnostics: [Diagnostic] = []
    var results: [RepoResult] = []
    var logs: [String] = []
    var auditEvents: [AuditEvent] = []
    var statusLine: String = "Ready"
    var running = false
    var generating = false
    var validating = false
    var selectedRepo: String?

    @ObservationIgnored let credentials: CredentialStore
    @ObservationIgnored private let store = AppStateStore()
    @ObservationIgnored private let engine = ScriptEngine()
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private let typescript = TypeScriptService.loadDefault()
    @ObservationIgnored private lazy var pipeline = ValidationPipeline(typescript: typescript)

    init(credentials: CredentialStore = KeychainCredentialStore()) {
        self.credentials = credentials
        if let snapshot = store.load() {
            settings = snapshot.settings
            if let job = snapshot.job {
                prompt = job.prompt
                scriptText = job.scriptSource
                paramsDraft = job.params
                results = job.results
                logs = job.logs
                auditEvents = job.auditEvents
                statusLine = job.lastRunStatus ?? "Restored previous job"
            }
        }
        if scriptText.isEmpty {
            loadGoldenRecipe()
        }
    }

    var typeCheckingAvailable: Bool { typescript != nil }
    var typeCheckerLabel: String {
        guard typescript != nil else { return "Type-check unavailable" }
        if let version = typescript?.compilerVersion { return "TypeScript \(version)" }
        return "TypeScript ready"
    }

    var selectedResult: RepoResult? {
        guard let selectedRepo else { return nil }
        return results.first { $0.id == selectedRepo }
    }

    func loadGoldenRecipe() {
        guard let recipe = ResourceLocator.goldenRecipe else { return }
        scriptText = recipe
        diagnostics = []
        statusLine = "Loaded recipe — Check to type-check, Run to execute"
    }

    // MARK: Client selection

    func githubClient() -> GitHubClient {
        if settings.useFixtureGitHub { return FixtureGitHubClient.demo() }
        let credentials = self.credentials
        return LiveGitHubClient(apiHost: settings.apiHost,
                                tokenProvider: { credentials.read(.githubToken) })
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
        let context = ScriptGenerationContext(organisation: settings.organisation)
        let promptText = prompt
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
                    statusLine = "Script generated — review before running"
                    generating = false
                    await validate()
                case .script:
                    scriptText = previousScript
                    statusLine = "Generation produced no script"
                    generating = false
                case .capabilityGap(let report):
                    scriptText = previousScript
                    surfaceCapabilityGap(report)
                    generating = false
                }
            } catch LLMClientError.capabilityGap(let report) {
                scriptText = previousScript
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

    @discardableResult
    func validate() async -> ValidatedScript? {
        guard !validating else { return nil }
        validating = true
        defer { validating = false }
        statusLine = typeCheckingAvailable ? "Type-checking against bulkgh.d.ts…" : "Checking…"
        let source = scriptText
        let pipeline = self.pipeline
        do {
            let validated = try await Task.detached(priority: .userInitiated) {
                try pipeline.validate(source: source)
            }.value
            diagnostics = validated.diagnostics
            var merged = validated.meta.params
            for (key, value) in paramsDraft where merged[key] != nil {
                merged[key] = value
            }
            paramsDraft = merged
            statusLine = "Valid — \(validated.meta.title)"
            return validated
        } catch let error as ValidationError {
            diagnostics = error.diagnostics
            statusLine = error.errorDescription ?? "Validation failed"
            return nil
        } catch {
            statusLine = "Validation failed: \(error.localizedDescription)"
            return nil
        }
    }

    func run() {
        guard !running else { return }
        runTask = Task { await runInternal() }
    }

    private func runInternal() async {
        guard let validated = await validate() else { return }
        running = true
        defer { running = false }
        results = []
        logs = []
        auditEvents = []
        selectedRepo = nil
        statusLine = "Running…"
        let outcome = await engine.run(javaScript: validated.javaScript,
                                       phase: validated.meta.phase,
                                       params: paramsDraft,
                                       github: githubClient(),
                                       organisation: settings.organisation,
                                       configuration: EngineConfiguration(settings: settings)) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        statusLine = "Run \(outcome.status.label)"
        results = outcome.results
        logs = outcome.logs
        auditEvents = outcome.auditEvents
        saveNow()
    }

    func cancel() {
        runTask?.cancel()
        statusLine = "Cancelling…"
    }

    private func handle(_ event: RunEvent) {
        switch event {
        case .log(let line):
            logs.append(line)
        case .progress(let line):
            logs.append("▸ \(line)")
        case .repo(let result):
            if let index = results.firstIndex(where: { $0.id == result.id }) {
                results[index] = result
            } else {
                results.append(result)
            }
        case .audit(let event):
            auditEvents.append(event)
        }
    }

    // MARK: Persistence

    func saveNow() {
        var job = Job(prompt: prompt)
        job.scriptSource = scriptText
        job.params = paramsDraft
        job.results = results
        job.logs = logs
        job.auditEvents = auditEvents
        job.lastRunStatus = statusLine
        try? store.save(AppStateSnapshot(settings: settings, job: job))
    }
}
