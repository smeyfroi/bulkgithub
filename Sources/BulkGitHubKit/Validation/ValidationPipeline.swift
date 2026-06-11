import Foundation
import JavaScriptCore

public struct ValidatedScript: Sendable {
    public let javaScript: String
    public let meta: ScriptMeta
    public let diagnostics: [Diagnostic]
}

public enum ValidationError: LocalizedError {
    case lintErrors([Diagnostic])
    case typeErrors([Diagnostic])
    case evaluationFailed(String)
    case metaInvalid(String)

    public var errorDescription: String? {
        switch self {
        case .lintErrors(let d): return "Lint errors: \(d.map(\.message).joined(separator: "; "))"
        case .typeErrors(let d):
            let errors = d.filter { $0.severity == .error }
            return "\(errors.count) type error(s): " + errors.prefix(3).map {
                "\($0.line):\($0.column) \($0.message)"
            }.joined(separator: "; ")
        case .evaluationFailed(let m): return "Script failed to evaluate: \(m)"
        case .metaInvalid(let m): return "Script contract violation: \(m)"
        }
    }

    public var diagnostics: [Diagnostic] {
        switch self {
        case .lintErrors(let d), .typeErrors(let d): return d
        case .evaluationFailed(let m), .metaInvalid(let m):
            return [Diagnostic(severity: .error, message: m)]
        }
    }
}

/// lint → type-check (against bulkgh.d.ts) → transpile → meta extraction.
/// Every script passes through here before the engine will run it.
public final class ValidationPipeline: @unchecked Sendable {

    private let typescript: TypeScriptService?

    public init(typescript: TypeScriptService?) {
        self.typescript = typescript
    }

    public var typeCheckingAvailable: Bool { typescript != nil }

    public func validate(source: String) throws -> ValidatedScript {
        let lint = ScriptLinter.lint(source)
        if lint.contains(where: { $0.severity == .error }) {
            throw ValidationError.lintErrors(lint)
        }

        var diagnostics = lint
        let javaScript: String
        if let typescript {
            // The declared phase decides which API surface exists for the
            // type-check: update scripts get the write declarations merged in;
            // check scripts cannot even type-check a write. Sniffed from the
            // source (meta extraction needs the transpiled JS, which we don't
            // have yet); verified for real during meta extraction below.
            let extraDeclaration = ResourceLocator.extraDeclaration(
                for: Self.sniffPhase(from: source))
            let typeDiagnostics = try typescript.check(source: source,
                                                       extraDeclaration: extraDeclaration)
            diagnostics += typeDiagnostics
            if typeDiagnostics.contains(where: { $0.severity == .error }) {
                throw ValidationError.typeErrors(diagnostics)
            }
            javaScript = try typescript.transpile(source: source)
        } else {
            // No compiler available: the script must already be plain JS.
            javaScript = source
        }

        let meta = try Self.extractMeta(fromJavaScript: javaScript)
        return ValidatedScript(javaScript: javaScript, meta: meta, diagnostics: diagnostics)
    }

    public static func sniffPhase(from source: String) -> JobPhase {
        guard let regex = try? NSRegularExpression(pattern: #"phase\s*:\s*"(check|update|merge)""#),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source),
              let phase = JobPhase(rawValue: String(source[range])) else { return .check }
        return phase
    }

    // MARK: - Meta extraction

    /// Evaluates the transpiled script in a bare context (no host bindings)
    /// and reads the `meta` declaration and `main` function. House rule:
    /// scripts contain only declarations at top level, so this is side-effect
    /// free; anything touching gh/job/parse at top level fails here, loudly.
    static func extractMeta(fromJavaScript javaScript: String) throws -> ScriptMeta {
        guard let vm = JSVirtualMachine(), let context = JSContext(virtualMachine: vm) else {
            throw ValidationError.evaluationFailed("could not create JS context")
        }
        var exception: String?
        context.exceptionHandler = { _, value in
            exception = value?.toString() ?? "unknown exception"
        }
        context.evaluateScript(javaScript)
        if let exception { throw ValidationError.evaluationFailed(exception) }

        let hasMain = context.evaluateScript("typeof main === 'function'")?.toBool() ?? false
        guard hasMain else {
            throw ValidationError.metaInvalid("script must define async function main()")
        }

        let metaJSON = context.evaluateScript(
            "typeof meta === 'object' && meta !== null ? JSON.stringify(meta) : null")
        guard let json = metaJSON, json.isString, let data = json.toString().data(using: .utf8) else {
            throw ValidationError.metaInvalid("script must declare const meta = { title, phase, ... }")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError.metaInvalid("meta must be a plain object")
        }

        let title = object["title"] as? String ?? "Untitled"
        let phaseRaw = object["phase"] as? String ?? "check"
        guard let phase = JobPhase(rawValue: phaseRaw) else {
            throw ValidationError.metaInvalid("meta.phase must be one of check/update/merge (was \"\(phaseRaw)\")")
        }
        var params: [String: String] = [:]
        if let rawParams = object["params"] as? [String: Any] {
            for (key, value) in rawParams {
                switch value {
                case let s as String: params[key] = s
                case let b as Bool: params[key] = b ? "true" : "false"
                case let n as NSNumber: params[key] = n.stringValue
                default:
                    throw ValidationError.metaInvalid("meta.params.\(key) must be a scalar")
                }
            }
        }
        let apiVersion = object["apiVersion"] as? Int ?? 1
        return ScriptMeta(title: title, phase: phase, params: params, apiVersion: apiVersion)
    }
}
