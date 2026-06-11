import Foundation
import JavaScriptCore

/// Runs the bundled TypeScript compiler inside a private JavaScriptCore
/// context to type-check generated scripts against the host API declaration
/// (bulkgh.d.ts) before they execute, and to transpile TS → JS.
///
/// This is the "tsc-in-JSC" spike from plan v2. The compiler context is
/// created lazily (first check pays the ~seconds-scale compiler boot) and is
/// confined to a serial queue.
public final class TypeScriptService: @unchecked Sendable {

    public enum ServiceError: LocalizedError {
        case compilerUnavailable(String)
        case callFailed(String)

        public var errorDescription: String? {
            switch self {
            case .compilerUnavailable(let m): return "TypeScript compiler unavailable: \(m)"
            case .callFailed(let m): return "TypeScript service failure: \(m)"
            }
        }
    }

    private let queue = DispatchQueue(label: "me.geo.bulkgithub.tsc")
    private let compilerSource: String
    private let libs: [String: String]
    private let apiDeclaration: String
    private var context: JSContext?
    public private(set) var compilerVersion: String?

    public init(compilerSource: String, libs: [String: String], apiDeclaration: String) {
        self.compilerSource = compilerSource
        self.libs = libs
        self.apiDeclaration = apiDeclaration
    }

    /// Loads compiler + libs + API declaration from the module bundle.
    public static func loadDefault() -> TypeScriptService? {
        guard let (compiler, libs) = ResourceLocator.typeScriptCompiler(),
              let api = ResourceLocator.apiDeclaration, !libs.isEmpty else { return nil }
        return TypeScriptService(compilerSource: compiler, libs: libs, apiDeclaration: api)
    }

    private static let glue = """
    globalThis.__bgh_check = (fileName, source, extraName, extraSource) => {
      const files = Object.assign({}, globalThis.__bgh_files);
      files[fileName] = source;
      const roots = [fileName, "bulkgh.d.ts"];
      if (extraName && extraSource) {
        files[extraName] = extraSource;
        roots.push(extraName);
      }
      const options = {
        target: ts.ScriptTarget.ES2020,
        lib: ["lib.es2022.d.ts"],
        strict: true,
        noEmit: true,
        types: [],
        skipLibCheck: true,
      };
      const host = {
        getSourceFile: (name, languageVersion) =>
          files[name] !== undefined
            ? ts.createSourceFile(name, files[name], languageVersion, true)
            : undefined,
        getDefaultLibFileName: () => "lib.es2022.d.ts",
        getDefaultLibLocation: () => "",
        writeFile: () => {},
        getCurrentDirectory: () => "",
        getDirectories: () => [],
        fileExists: (name) => files[name] !== undefined,
        readFile: (name) => files[name],
        getCanonicalFileName: (f) => f,
        useCaseSensitiveFileNames: () => true,
        getNewLine: () => "\\n",
      };
      const program = ts.createProgram(roots, options, host);
      const diagnostics = ts.getPreEmitDiagnostics(program);
      return JSON.stringify(diagnostics.map((d) => {
        let line = 0, character = 0;
        if (d.file && d.start !== undefined) {
          const lc = d.file.getLineAndCharacterOfPosition(d.start);
          line = lc.line + 1;
          character = lc.character + 1;
        }
        return {
          message: ts.flattenDiagnosticMessageText(d.messageText, "\\n"),
          line, character,
          category: d.category,
          code: d.code,
          file: d.file ? d.file.fileName : null,
        };
      }));
    };
    globalThis.__bgh_transpile = (source) => {
      const out = ts.transpileModule(source, {
        compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.None },
      });
      return out.outputText;
    };
    """

    private func ensureContext() throws -> JSContext {
        if let context { return context }
        guard let vm = JSVirtualMachine(), let ctx = JSContext(virtualMachine: vm) else {
            throw ServiceError.compilerUnavailable("could not create JS context")
        }
        ctx.name = "TypeScript compiler"
        var bootError: String?
        ctx.exceptionHandler = { _, exception in
            bootError = exception?.toString() ?? "unknown exception"
        }
        ctx.evaluateScript(compilerSource)
        if let bootError { throw ServiceError.compilerUnavailable(bootError) }
        guard let tsValue = ctx.objectForKeyedSubscript("ts"), tsValue.isObject else {
            throw ServiceError.compilerUnavailable("typescript.js did not define a global `ts`")
        }
        compilerVersion = tsValue.objectForKeyedSubscript("version")?.toString()

        var allFiles = libs
        allFiles["bulkgh.d.ts"] = apiDeclaration
        ctx.setObject(allFiles, forKeyedSubscript: "__bgh_files" as NSString)

        ctx.evaluateScript(Self.glue)
        if let bootError { throw ServiceError.compilerUnavailable(bootError) }
        context = ctx
        return ctx
    }

    private struct TSDiagnostic: Decodable {
        let message: String
        let line: Int
        let character: Int
        let category: Int
        let code: Int
        let file: String?
    }

    /// Type-checks a script against the host API. Update scripts pass the
    /// extra declaration so the write surface exists for them — and only for
    /// them. Returns diagnostics (errors block execution; the caller decides).
    public func check(source: String, fileName: String = "script.ts",
                      extraDeclaration: String? = nil) throws -> [Diagnostic] {
        try queue.sync {
            let ctx = try ensureContext()
            var callError: String?
            ctx.exceptionHandler = { _, exception in
                callError = exception?.toString() ?? "unknown exception"
            }
            guard let fn = ctx.objectForKeyedSubscript("__bgh_check"),
                  let result = fn.call(withArguments: [fileName, source,
                                                       extraDeclaration == nil ? "" : "bulkgh.update.d.ts",
                                                       extraDeclaration ?? ""]),
                  result.isString, let json = result.toString(),
                  let data = json.data(using: .utf8) else {
                throw ServiceError.callFailed(callError ?? "check returned no result")
            }
            if let callError { throw ServiceError.callFailed(callError) }
            let raw = try JSONDecoder().decode([TSDiagnostic].self, from: data)
            return raw.map { d in
                let severity: Diagnostic.Severity = d.category == 1 ? .error
                    : d.category == 0 ? .warning : .info
                let inScript = d.file == nil || d.file == fileName
                let message = inScript ? d.message : "[\(d.file!)] \(d.message)"
                return Diagnostic(severity: severity, message: message,
                                  line: inScript ? d.line : 0,
                                  column: inScript ? d.character : 0,
                                  code: d.code)
            }
        }
    }

    /// Strips types: TS → ES2020 JS suitable for the script engine.
    public func transpile(source: String) throws -> String {
        try queue.sync {
            let ctx = try ensureContext()
            var callError: String?
            ctx.exceptionHandler = { _, exception in
                callError = exception?.toString() ?? "unknown exception"
            }
            guard let fn = ctx.objectForKeyedSubscript("__bgh_transpile"),
                  let result = fn.call(withArguments: [source]),
                  result.isString, let js = result.toString() else {
                throw ServiceError.callFailed(callError ?? "transpile returned no result")
            }
            if let callError { throw ServiceError.callFailed(callError) }
            return js
        }
    }
}
