import SwiftUI
import BulkGitHubKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GitHubSettingsTab()
                .tabItem { Label("GitHub", systemImage: "network") }
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
            BehaviorSettingsTab()
                .tabItem { Label("Behavior", systemImage: "gearshape") }
        }
        .frame(width: 520)
        .padding()
    }
}

struct GitHubSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var tokenDraft = ""
    @State private var tokenStored = false
    @State private var testResult = ""

    var body: some View {
        @Bindable var model = model
        Form {
            TextField("Organisation", text: $model.settings.organisation)
            TextField("Web host", text: $model.settings.webHost)
            TextField("API host", text: $model.settings.apiHost)

            LabeledContent("Personal access token") {
                VStack(alignment: .trailing, spacing: 6) {
                    SecureField("ghp_…", text: $tokenDraft)
                        .frame(width: 260)
                    HStack {
                        if tokenStored {
                            Label("Stored in Keychain", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                        Button("Save") {
                            try? model.credentials.write(.githubToken, value: tokenDraft)
                            tokenDraft = ""
                            tokenStored = model.credentials.read(.githubToken) != nil
                        }
                        .disabled(tokenDraft.isEmpty)
                        Button("Clear") {
                            try? model.credentials.delete(.githubToken)
                            tokenStored = false
                        }
                        .disabled(!tokenStored)
                    }
                }
            }

            Toggle("Use fixture data (offline development)", isOn: $model.settings.useFixtureGitHub)

            LabeledContent("Connection") {
                HStack {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Test") { test() }
                        .disabled(model.settings.useFixtureGitHub)
                }
            }

            Text("Check scripts need repository metadata and content read access. Applying updates and merging PRs also needs content and pull-request write access (the classic repo scope, or a fine-grained equivalent).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { tokenStored = model.credentials.read(.githubToken) != nil }
        .onDisappear { model.saveNow() }
    }

    private func test() {
        guard let token = model.credentials.read(.githubToken), !token.isEmpty else {
            testResult = "No token stored"
            return
        }
        testResult = "Testing…"
        let apiHost = model.settings.apiHost
        Task {
            do {
                let login = try await Self.whoAmI(apiHost: apiHost, token: token)
                testResult = "OK — authenticated as \(login)"
            } catch {
                testResult = error.localizedDescription
            }
        }
    }

    private static func whoAmI(apiHost: String, token: String) async throws -> String {
        guard let url = URL(string: apiHost)?.appendingPathComponent("user") else {
            throw GitHubClientError.invalidResponse("bad API host")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubClientError.invalidResponse("non-HTTP response")
        }
        guard http.statusCode == 200 else {
            throw GitHubClientError.http(http.statusCode, "check token and host")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String else {
            throw GitHubClientError.invalidResponse("unexpected /user payload")
        }
        return login
    }
}

struct AISettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var keyDraft = ""
    @State private var keyStored = false
    @State private var testResult = ""

    var body: some View {
        @Bindable var model = model
        Form {
            LabeledContent("API key") {
                VStack(alignment: .trailing, spacing: 6) {
                    SecureField("sk-ant-…", text: $keyDraft)
                        .frame(width: 260)
                    HStack {
                        if keyStored {
                            Label("Stored in Keychain", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                        Button("Save") {
                            try? model.credentials.write(.anthropicAPIKey, value: keyDraft)
                            keyDraft = ""
                            keyStored = model.credentials.read(.anthropicAPIKey) != nil
                        }
                        .disabled(keyDraft.isEmpty)
                        Button("Clear") {
                            try? model.credentials.delete(.anthropicAPIKey)
                            keyStored = false
                        }
                        .disabled(!keyStored)
                    }
                }
            }

            TextField("Model", text: $model.settings.aiModel, prompt: Text(AnthropicClient.defaultModel))

            Toggle("Use mock LLM (offline development)", isOn: $model.settings.useMockLLM)

            LabeledContent("Connection") {
                HStack {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Test") { test() }
                        .disabled(model.settings.useMockLLM)
                }
            }

            Text("The system prompt carries the host API declaration and the house rules; generated scripts are always type-checked and shown for review before they can run.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { keyStored = model.credentials.read(.anthropicAPIKey) != nil }
        .onDisappear { model.saveNow() }
    }

    private func test() {
        testResult = "Testing…"
        let client = AnthropicClient(model: model.settings.aiModel,
                                     keyProvider: { [credentials = model.credentials] in
                                         credentials.read(.anthropicAPIKey)
                                     })
        Task {
            do {
                testResult = try await client.testConnection()
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}

struct BehaviorSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Stepper("Max concurrent repository operations: \(model.settings.maxConcurrentOps)",
                    value: $model.settings.maxConcurrentOps, in: 1...32)

            Stepper("Run time limit: \(Int(model.settings.maxRunSeconds))s",
                    value: $model.settings.maxRunSeconds, in: 60...3600, step: 60)

            Stepper("Script sync budget: \(Int(model.settings.maxSyncBudgetSeconds))s",
                    value: $model.settings.maxSyncBudgetSeconds, in: 10...600, step: 10)
                .help("Total synchronous JavaScript execution allowed per run (watchdog)")
        }
        .formStyle(.grouped)
        .onDisappear { model.saveNow() }
    }
}
