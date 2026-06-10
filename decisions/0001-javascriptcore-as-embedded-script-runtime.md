# ADR 0001: JavaScriptCore as the Embedded Script Runtime for LLM-Generated Operations

- **Status:** Accepted
- **Date:** 2026-06-10
- **Decision owner:** Steve
- **Input:** AI-assisted options exploration (Claude, 2026-06-10); survey of the existing bulk-update scripts in `/Users/steve/Development/geome/dev-handbook/scripts/`

## Context

The bulkgithub app is a native Swift macOS workbench for finding and bulk-updating repositories across a GitHub organisation. The initial plan (`plans/native-macos-bulkgithub-app-plan.md`, now superseded) had the LLM translate natural-language requests into a *structured plan* — a closed YAML schema of search predicates (`file exists`, `yaml key equals value`, `text contains regex`, …) and, later, structured update plans — executed by Swift code.

The structured-schema approach was rejected because the predicate and update vocabulary inevitably sprawls as use cases diversify. The evidence is the prior art: roughly 17 LLM-generated Ruby scripts in dev-handbook (Dependabot config sync, deploy-workflow migration, UAT incident removal, SAR workflow rollout, …). Each task's *business logic* — the `DependabotPatcher` class, the workflow YAML rewriting — is arbitrary code that no reasonable closed schema could express. Everything *around* the business logic, however, is highly stereotyped: check → update → merge phasing, dry-run by default with explicit `--write`, canary-repo-first rollout, idempotent branch/PR naming, per-repo error isolation, skip reasons, state files between phases.

The superseding direction (recorded in plan v2) is therefore: **the LLM generates an executable script (the volatile business logic); the native app provides a small, stable capability API plus structurally enforced guardrails (the stereotyped safety layer).** That direction requires choosing an embeddable script runtime for a self-contained native macOS app — the subject of this ADR.

### Constraints at decision time

- Self-contained native Swift macOS app: SwiftUI frontend, no web UI, no dependence on user-installed interpreters (macOS system scripting runtimes are deprecated or removed).
- Distribution is Developer ID + notarization, direct download — **not** the Mac App Store. Bundled interpreters and sandboxed XPC helper processes are all permissible; distribution forces no choice.
- Generated scripts execute **only inside the app**. There is no requirement to run them standalone in a terminal or CI, so the host API need not mimic octokit or any real-world library.
- Trust model: a human reviews every generated script before execution, as in the existing dev-handbook workflow. Sandboxing is defense-in-depth, not the primary control. Primary controls are review plus capability-scoped handles (read-only handles for check scripts, recording handles for dry runs, guarded handles for writes).
- No team language preference between Ruby and JavaScript/TypeScript for review ergonomics (explicitly confirmed).
- Scripts are written by an LLM on every use, so the runtime's language should be one LLMs generate with high reliability.

## Decision

**Embed JavaScriptCore — the JS engine that ships with macOS — as the script runtime. Generated scripts are TypeScript against a versioned, typed host API; the app type-checks each script against that API before execution, transpiles it, and evaluates it in a `JSContext` that exposes only capability-handle globals.**

Key elements:

- `JavaScriptCore.framework` is a system framework: nothing to bundle, sign, or maintain across macOS releases.
- A fresh JSC context has **no ambient capabilities** — no filesystem, network, process, or timer access exists unless injected. The injected handles (`gh`, `job`, `parse`) are the script's entire world; capability security is the default state rather than an added layer.
- The GitHub token and the LLM API key never enter the script context. Host functions sign requests on the Swift side, so a generated script cannot leak a credential it never sees.
- The host API is published to the LLM and to the type-checker as a TypeScript declaration file (`bulkgh.d.ts`). The TypeScript compiler (pure JavaScript, bundled as a resource and run in a secondary JSC context) validates every generated or hand-edited script before it can run — hallucinated or misspelled API calls are caught in the review pane, not at repo 137 of 200.
- Host functions return Promises (`JSValue(newPromiseIn:)`), so scripts use ordinary `async/await`. Swift concurrency owns scheduling, rate limiting, and cancellation beneath the bridge. Runaway pure-JS loops are bounded by the JSC watchdog (`JSContextGroupSetExecutionTimeLimit`).

## Options considered

### Option 1 — JavaScriptCore + TypeScript-typed host API (chosen)

- **For:** zero bundled runtime; capability security by construction; the strongest LLM code-generation fluency of any language; machine-checkable generated code via the bundled TypeScript compiler; clean `async/await` fit with Swift concurrency and cancellation; the most "native macOS app" answer.
- **Against:** no continuity with the Ruby script corpus (the *house style* — phasing, canary, skip reasons — still transfers via the system prompt); JavaScript's thin standard library means the host must supply YAML/TOML/JSON parsing and diff helpers (desirable anyway, since Swift-side parsing was already planned).

### Option 2a — mruby, statically linked

- **For:** designed for embedding; a few MB compiled into the app; capability control *by omission* (build without File/IO/Socket gems and the language physically lacks them).
- **Against:** mruby is not CRuby — no gems, reduced stdlib, dialect gaps. An LLM steeped in CRuby idiom produces code that almost-runs (`require 'yaml'`, kwargs edge cases), and every "almost" is friction in the review loop, a permanent tax.

### Option 2b — Full CRuby embedded in a sandboxed XPC helper

- **For:** real CRuby — exactly the dialect of the existing corpus; strong containment via a helper process with a tight sandbox profile (no network; all `gh.*` calls forwarded over XPC to the main app, which holds the token); a crashed interpreter cannot take down the app; kill-to-cancel.
- **Against:** the heaviest ongoing ownership — building, signing, and notarizing a ~40–60 MB Ruby runtime forever; crusty C embedding API (GVL, signal handling); and the main argument (Ruby continuity / standalone reuse) was nullified by the app-only and no-language-preference constraints.

### Option 3 — WebAssembly runtime (WasmKit or wasmtime) + ruby.wasm or other engines

- **For:** the strongest sandbox guarantee (deny-by-default, host imports are the only capabilities, fuel metering); language becomes a plugin (ruby.wasm gives real CRuby *and* hard sandboxing); future-proof if unreviewed third-party recipe scripts ever become a goal.
- **Against:** the most engineering by a clear margin — WASI's synchronous host-call model fits awkwardly with Swift concurrency; materially worse debugging and error reporting (which the review-loop UX depends on); tens of MB of bundled interpreter; constrained gem/library story. Pays the project's highest complexity bill for a guarantee the review-before-run trust model does not require.

### Comparison

| | 1. JavaScriptCore | 2a. mruby | 2b. CRuby + XPC | 3. WASM |
|---|---|---|---|---|
| Runtime to bundle/maintain | none (system) | small, static | ~50 MB, self-owned | runtime + interpreter, tens of MB |
| Sandbox strength | capability-by-construction | capability-by-omission | process sandbox | strongest |
| LLM generation quality | best | CRuby-isms break | excellent | depends on language |
| Pre-run validation | TS type-check against API | syntax only | syntax only | compile step |
| Async/cancellation fit | native | manual | XPC kill | clunky (sync WASI) |
| Build effort | lowest | medium | high | highest |

## Rationale

Each constraint answer removed a pull toward an alternative: Developer ID distribution makes everything *possible* but nothing *necessary*; app-only execution removes the octokit-compatibility argument for Ruby; review-before-run makes WASM's hard sandbox surplus to requirements; no language preference removes Ruby's continuity claim. What remains are JavaScriptCore's unshared strengths: it is free, already on every Mac, capability-secure by default, paired with the language LLMs generate best, and uniquely able to machine-check generated scripts against the host API before execution. That last property strengthens precisely the activity the trust model is built on — a human reviewing and trusting the script.

## Consequences

**Positive**

- No interpreter to build, sign, notarize, or chase across macOS updates.
- Dry-run, write-gating, branch-name and repo-allowlist guardrails are enforced by which handle is injected — structural, not conventional.
- Credentials are physically unreadable from script code.
- Generated scripts are validated against `bulkgh.d.ts` before they can run; the declaration file doubles as the API contract given to the LLM.
- House rules from the dev-handbook corpus (dry-run default, canary-first, idempotent branches, skip reasons) move into the system prompt and recipe examples, where they apply to any task without new Swift code.

**Negative / accepted trade-offs**

- Reviewers read TypeScript, not Ruby; existing Ruby review instincts transfer only at the pattern level.
- The host must provide parsing (YAML/JSON/TOML), diffing, and any other stdlib-ish helpers scripts need.
- Running the TypeScript compiler inside JSC needs an early feasibility spike (latency, memory). Fallback if unacceptable: transpile-only plus runtime API-shape validation — this weakens pre-run checking but does not invalidate the runtime choice.

**Neutral**

- Process-level isolation (moving the JSC context into a sandboxed XPC helper) remains available later with no host-API change; it composes with this decision rather than competing with it.

## Revisit triggers

- **Review ergonomics:** if reading generated TypeScript grates after sustained real use, Option 2b (CRuby in a sandboxed XPC helper) preserves the entire capability-handle architecture — only the interpreter and bridge change.
- **Trust model shift:** if scripts ever run unreviewed, or third parties contribute recipes, move JSC into a sandboxed XPC helper first; revisit Option 3 (WASM) if multi-language plugins or hard guarantees become requirements.
- **Standalone reuse:** if generated scripts must someday run outside the app (terminal/CI), revisit — that requirement favours Ruby + an octokit-compatible shim or Node-compatible JavaScript, and reshapes the host API toward a real library's surface.
