import Foundation
import Testing
@testable import BulkGitHubKit

@Suite("Streaming generation")
struct StreamingTests {

    @Test("mock client streams in chunks that assemble to the full script")
    func mockStreams() async throws {
        let client = MockLLMClient()
        let context = ScriptGenerationContext(organisation: "example-org")
        let prompt = "find repos with a file at deploy/prod.yml where the key account_id has a value of \"42\""

        var raw = ""
        var deltas = 0
        for try await event in client.streamScript(prompt: prompt, context: context) {
            if case .delta(let chunk) = event {
                raw += chunk
                deltas += 1
            }
        }
        #expect(deltas > 5, "expected line-by-line chunks, got \(deltas)")

        guard case .script(let streamed) = PromptLibrary.parseGeneration(from: raw) else {
            Issue.record("expected a script")
            return
        }
        let blocking = try await client.makeScript(prompt: prompt, context: context)
        #expect(streamed == blocking.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("default streamScript falls back to one delta")
    func defaultFallback() async throws {
        struct OneShot: LLMClient {
            func makeScript(prompt: String, context: ScriptGenerationContext) async throws -> String {
                "const meta = { title: \"x\", phase: \"check\" };"
            }
            func reviseScript(_ script: String, prompt: String, diagnostics: [Diagnostic],
                              context: ScriptGenerationContext) async throws -> String { script }
        }
        var deltas: [String] = []
        for try await event in OneShot().streamScript(prompt: "p",
                                                      context: .init(organisation: "example-org")) {
            if case .delta(let chunk) = event { deltas.append(chunk) }
        }
        #expect(deltas.count == 1)
        #expect(deltas[0].hasPrefix("const meta"))
    }

    @Test("live view of a partially streamed response")
    func liveView() {
        // Nothing visible until the fence's language token line completes.
        #expect(PromptLibrary.liveScript(fromPartial: "```typescri") == "")
        // Prose before the fence is dropped.
        #expect(PromptLibrary.liveScript(fromPartial: "Here you go:\n```typescript\nconst a = 1;")
                == "const a = 1;")
        // Closing fence is trimmed once it lands.
        #expect(PromptLibrary.liveScript(fromPartial: "```typescript\nconst a = 1;\n```")
                == "const a = 1;")
        // Unfenced text passes through (default fallback path).
        #expect(PromptLibrary.liveScript(fromPartial: "const a = 1;") == "const a = 1;")
    }

    @Test("SSE lines parse to text deltas, other events are ignored")
    func sseParsing() {
        let text = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"const a"}}"#
        #expect(AnthropicClient.textDelta(fromSSELine: text) == "const a")

        let thinking = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#
        #expect(AnthropicClient.textDelta(fromSSELine: thinking) == nil)

        #expect(AnthropicClient.textDelta(fromSSELine: "event: content_block_delta") == nil)
        #expect(AnthropicClient.textDelta(fromSSELine: #"data: {"type":"message_stop"}"#) == nil)
        #expect(AnthropicClient.textDelta(fromSSELine: "") == nil)

        let failure = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        #expect(AnthropicClient.streamFailure(fromSSELine: failure) == "Overloaded")
        #expect(AnthropicClient.streamFailure(fromSSELine: text) == nil)
    }
}
