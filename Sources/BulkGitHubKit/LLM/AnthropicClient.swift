import Foundation

/// Anthropic Messages API client (raw URLSession — there is no official Swift
/// SDK). Generates check scripts from natural-language prompts.
///
/// Not exercised by automated tests or default app flows: the app ships with
/// the mock client selected until the user flips Settings → AI → "Use mock".
/// The API key comes from Keychain via the provider closure and never enters
/// script space.
public final class AnthropicClient: LLMClient, @unchecked Sendable {
    public typealias KeyProvider = @Sendable () -> String?

    public static let defaultModel = "claude-opus-4-8"

    private let endpoint: URL
    private let model: String
    private let keyProvider: KeyProvider
    private let session: URLSession
    private let maxTokens = 16000

    public init(model: String = AnthropicClient.defaultModel,
                keyProvider: @escaping KeyProvider,
                endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
                session: URLSession = .shared) {
        self.model = model.isEmpty ? Self.defaultModel : model
        self.keyProvider = keyProvider
        self.endpoint = endpoint
        self.session = session
    }

    public func makeScript(prompt: String, context: ScriptGenerationContext) async throws -> String {
        let user = """
        Write a \(context.phase.rawValue) script for this request:

        \(prompt)
        """
        return try await complete(userContent: user, context: context)
    }

    public func reviseScript(_ script: String, prompt: String, diagnostics: [Diagnostic],
                             context: ScriptGenerationContext) async throws -> String {
        let issues = diagnostics.prefix(20)
            .map { "- line \($0.line), col \($0.column): \($0.message)" }
            .joined(separator: "\n")
        let user = """
        The previous script for the request below failed validation. Fix it and \
        return the complete corrected script.

        Request:
        \(prompt)

        Previous script:
        ```typescript
        \(script)
        ```

        Validation diagnostics:
        \(issues)
        """
        return try await complete(userContent: user, context: context)
    }

    private func complete(userContent: String, context: ScriptGenerationContext) async throws -> String {
        guard let key = keyProvider(), !key.isEmpty else {
            throw LLMClientError.missingAPIKey
        }
        guard let apiDeclaration = ResourceLocator.apiDeclaration else {
            throw LLMClientError.invalidResponse("bulkgh.d.ts missing from bundle")
        }

        // The system prompt (house rules + API declaration) is a stable prefix
        // shared across every generation — mark it cacheable.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "thinking": ["type": "adaptive"],
            "system": [[
                "type": "text",
                "text": PromptLibrary.systemPrompt(apiDeclaration: apiDeclaration,
                                                   organisation: context.organisation),
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": [["role": "user", "content": userContent]],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMClientError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                let retry = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                throw LLMClientError.rateLimited(retryAfter: retry)
            }
            let message = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw LLMClientError.http(http.statusCode, message)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw LLMClientError.invalidResponse("missing content array")
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else {
            let stop = (json["stop_reason"] as? String) ?? "unknown"
            throw LLMClientError.invalidResponse("no text content (stop_reason: \(stop))")
        }
        return PromptLibrary.extractCode(from: text)
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    /// Minimal live round-trip for the Settings test-connection button.
    public func testConnection() async throws -> String {
        guard let key = keyProvider(), !key.isEmpty else { throw LLMClientError.missingAPIKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]],
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMClientError.http(http.statusCode, Self.errorMessage(from: data) ?? "")
        }
        return "OK (\(model))"
    }
}
