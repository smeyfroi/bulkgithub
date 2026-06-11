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
        try await complete(userContent: Self.userMessage(for: prompt, context: context),
                           context: context)
    }

    private static func userMessage(for prompt: String, context: ScriptGenerationContext) -> String {
        let kind = context.phase == .update
            ? "an update (dry-run) script"
            : "a \(context.phase.rawValue) script"
        return """
        Write \(kind) for this request:

        \(prompt)
        """
    }

    /// SSE streaming via the Messages API (stream: true). Yields raw text
    /// deltas; the caller accumulates and parses the final response.
    public func streamScript(prompt: String, context: ScriptGenerationContext)
        -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try self.requestBody(
                        userContent: Self.userMessage(for: prompt, context: context),
                        context: context,
                        stream: true)
                    let request = try self.urlRequest(body: body)
                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMClientError.invalidResponse("non-HTTP response")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                            if errorBody.count > 4000 { break }
                        }
                        if http.statusCode == 429 {
                            throw LLMClientError.rateLimited(retryAfter: nil)
                        }
                        throw LLMClientError.http(http.statusCode,
                                                  Self.errorMessage(from: Data(errorBody.utf8)) ?? errorBody)
                    }
                    for try await line in bytes.lines {
                        if let delta = Self.textDelta(fromSSELine: line) {
                            continuation.yield(.delta(delta))
                        } else if let failure = Self.streamFailure(fromSSELine: line) {
                            throw LLMClientError.invalidResponse(failure)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Extracts the text chunk from one SSE line, or nil for any other event
    /// (thinking deltas, block boundaries, pings, "event:" lines).
    static func textDelta(fromSSELine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String) == "content_block_delta",
              let delta = object["delta"] as? [String: Any],
              (delta["type"] as? String) == "text_delta" else { return nil }
        return delta["text"] as? String
    }

    /// Detects a mid-stream error event.
    static func streamFailure(fromSSELine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String) == "error" else { return nil }
        let error = object["error"] as? [String: Any]
        return (error?["message"] as? String) ?? "stream error"
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

    /// Shared body for blocking and streaming requests. The system prompt
    /// (house rules + API declaration) is a stable prefix shared across every
    /// generation — marked cacheable.
    private func requestBody(userContent: String, context: ScriptGenerationContext,
                             stream: Bool) throws -> [String: Any] {
        guard var apiDeclaration = ResourceLocator.apiDeclaration else {
            throw LLMClientError.invalidResponse("bulkgh.d.ts missing from bundle")
        }
        if let extra = ResourceLocator.extraDeclaration(for: context.phase) {
            apiDeclaration += "\n\n" + extra
        }
        var body: [String: Any] = [
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
        if stream { body["stream"] = true }
        return body
    }

    private func urlRequest(body: [String: Any]) throws -> URLRequest {
        guard let key = keyProvider(), !key.isEmpty else {
            throw LLMClientError.missingAPIKey
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func complete(userContent: String, context: ScriptGenerationContext) async throws -> String {
        let request = try urlRequest(body: requestBody(userContent: userContent,
                                                       context: context, stream: false))

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
        switch PromptLibrary.parseGeneration(from: text) {
        case .script(let script):
            return script
        case .capabilityGap(let report):
            throw LLMClientError.capabilityGap(report)
        }
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
