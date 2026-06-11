# Native macOS Bulk GitHub App - Handoff Plan v2 (Script-Host Architecture)

> Supersedes [native-macos-bulkgithub-app-plan.md](native-macos-bulkgithub-app-plan.md) (2026-06-10). The structured search/update plan schema is replaced by LLM-generated scripts running on an embedded JavaScriptCore host. Runtime choice and alternatives are recorded in [ADR 0001](../decisions/0001-javascriptcore-as-embedded-script-runtime.md).

## Context

The goal is unchanged: a native macOS app for working across GitHub repositories in an organisation. A user describes what they want in natural language; an AI turns that into something executable; the app finds, verifies, and (in later phases) updates matching repositories safely — dry-run diffs, branches, PRs, manual verification pause, guarded squash-merge, and cancellation.

What changed from v1: the AI no longer produces a structured plan against a fixed predicate schema. The predicate vocabulary (`yaml key equals`, `text contains regex`, …) sprawls as use cases diversify, and it can never express real per-task business logic. Instead, **the AI generates a TypeScript script; the app provides a small, stable capability API and structurally enforced guardrails.** The schema does not disappear — it shrinks into the host API surface (~15 calls) and stops growing with use cases. New use cases become new prompts and recipe examples, not new Swift code.

The app must be a native Swift macOS app. SwiftUI frontend, no web views. JavaScriptCore is the *script engine only* — it renders nothing and owns no UI.

The product model is distilled from the existing bulk-update workflow at:

```text
/Users/steve/Development/geome/dev-handbook/scripts/
```

Those ~17 LLM-generated Ruby scripts establish the house style the app must preserve: check → update → merge phasing, dry-run by default, canary/single-repo first, explicit write mode, clear skip reasons, idempotent branches and PRs, guarded merge as a separate step, per-repo error isolation, state passed between phases. In v2 these stop being conventions inside each script and become properties of the host.

Network is currently unreliable. Do not start live GitHub or LLM integration work until the user says to proceed.

## Product Shape

A "bulk repo workbench", not a chatbot.

A **job** is the unit of work. A job has phases, each backed by a generated script and a capability mode:

1. **Check** — read-only script finds and verifies matching repositories.
2. **Review** — user inspects verified matches, evidence, and skips.
3. Later: **Update (dry-run)** — script runs against a recording handle; produces a reviewable execution plan with diffs.
4. Later: **Update (write)** — same script re-runs against a guarded live handle for the repos the user selected.
5. Later: **Merge** — script squash-merges approved PRs under precondition checks.
6. Later: **Cancel** — close raised PRs and delete only job-created branches.

Assume one active job at a time for the first implementation. Saved jobs and concurrency can come later unless they fall out of the data model naturally.

## Architecture Overview

Two layers with a sharp boundary:

- **Volatile layer (LLM-generated, per task):** the script. Search queries, file parsing, match logic, content transformation. Reviewed and editable by the user before every run.
- **Stable layer (native Swift, built once):** the capability handles, GitHub client, rate limiting, pagination, concurrency, audit log, dry-run recording, write guardrails, persistence, UI.

Script lifecycle:

1. User writes a natural-language prompt (plus picks a phase/recipe).
2. LLM returns a TypeScript script targeting the published host API (`bulkgh.d.ts`).
3. App type-checks the script against `bulkgh.d.ts` in-process; diagnostics render in the editor. Failures can auto-feed a regeneration round-trip.
4. User reviews and optionally edits the script (re-check on edit).
5. App transpiles and evaluates it in a `JSContext` exposing only the capability handles for the current phase/mode.
6. Per-repo results stream into the native results table; every effectful host call lands in the audit log.
7. For updates: dry-run first (recording handle), then user arms write mode in the UI and selects repos; the script re-runs against the guarded live handle.

Credentials never enter the script context. Host functions sign GitHub requests Swift-side from Keychain. A script cannot read, log, or exfiltrate the token.

## Script Contract

A script is a single TypeScript file with two top-level declarations:

```ts
const meta = {
  title: "Find prod.yml account_id matches",
  phase: "check",                          // "check" | "update" | "merge"
  params: {                                // surfaced as native editable fields
    org: "geome",
    accountId: "481832923858",
  },
};

async function main(): Promise<void> {
  // ... uses gh / job / parse globals
}
```

The app evaluates the file, reads `meta`, renders `params` as native form fields (edit without re-prompting the LLM), then invokes `main()`. Edited param values are visible to the script via `job.params`.

Scripts declare the host API version they target; the app refuses to run a script against an incompatible API and offers regeneration.

## Host API (`bulkgh.d.ts` sketch)

Final surface is a phase-1 deliverable; this sketch covers all 17 dev-handbook scripts. Keep it minimal — every addition is forever.

```ts
interface Repo {
  fullName: string;            // "geome/service-foo"
  name: string;
  defaultBranch: string;
  archived: boolean;
  private: boolean;
}

interface PR {
  repo: string;
  number: number;
  headRef: string;
  headSha: string;
  state: "open" | "closed" | "merged";
  url: string;
}

interface GitHub {
  // Read — present on every handle
  listOrgRepos(): Promise<Repo[]>;                 // host-paginated
  searchCode(query: string): Promise<Repo[]>;      // candidates only, never proof
  getContent(repo: Repo | string, path: string, ref?: string): Promise<string | null>; // null = absent
  getRef(repo: Repo | string, ref: string): Promise<{ sha: string } | null>;
  listPRs(repo: Repo | string, opts?: { head?: string; state?: "open" | "closed" | "all" }): Promise<PR[]>;
  searchPRs(query: string): Promise<PR[]>;

  // Write — absent on read-only handles; recorded on dry-run handles; guarded on live handles
  createBranch(repo: Repo | string, name: string, fromSha: string): Promise<{ sha: string }>;
  putContent(repo: Repo | string, path: string, content: string,
             opts: { branch: string; message: string; expectedSha?: string }): Promise<void>;
  createPR(repo: Repo | string, opts: { head: string; title: string; body: string }): Promise<PR>;
  mergePR(pr: PR, opts: { method: "squash"; expectedHeadSha: string }): Promise<void>;
  closePR(pr: PR): Promise<void>;
  deleteBranch(repo: Repo | string, name: string): Promise<void>;   // job-created branches only
}

interface Job {
  reportMatch(repo: Repo | string, evidence: { path: string; excerpt: string; explanation?: string }): void;
  skip(repo: Repo | string, reason: string): void;
  error(repo: Repo | string, message: string): void;
  progress(message: string): void;
  log(message: string): void;
  readState<T>(key: string): T | null;     // typed artifacts passed between phases
  writeState<T>(key: string, value: T): void;
  params: Record<string, string>;          // resolved meta.params after user edits
}

interface Parse {
  yaml(text: string): unknown;
  json(text: string): unknown;
  toml(text: string): unknown;
}

declare const gh: GitHub;
declare const job: Job;
declare const parse: Parse;
```

Host-side responsibilities (never the script's): pagination, rate-limit pacing and backoff, the max-concurrency setting (scripts may fan out with `Promise.all` naively; the host queues), retries on transient failures, URL building, audit logging, cancellation.

## Capability Modes and Guardrails

The handle injected into the context is the enforcement mechanism — the v1 rule "AI produces plans, not operations" becomes "scripts operate a capability handle; the app decides what the handle can do".

- **Read-only handle (check phase):** write methods do not exist on the object. A check script cannot mutate anything, regardless of what the LLM wrote.
- **Recording handle (update dry-run):** reads are live; writes record intended actions and return synthesized-but-plausible responses (fake branch SHA, fake PR number, flagged as synthetic) so read-modify-write logic flows. Output is an **execution plan**: per-repo action lists and before/after content diffs, rendered natively for review.
- **Guarded live handle (update write):** writes execute, subject to: branch names must carry the job prefix (`bulkgh/<job-slug>/…`); writes only to repos the user selected in the results table; `expectedSha`/`expectedHeadSha` preconditions verified before mutating; destructive classes (merge, close, delete) require the per-job confirmation setting.
- **Merge handle:** only PRs in the job's artifact registry are visible to merge/close/delete; `mergePR` requires `expectedHeadSha` and re-verifies state before acting.

Cross-cutting rules:

- `job.reportMatch` requires that the script actually fetched content for that repo this run (the handle tracks `getContent` receipts). "GitHub search results are candidate evidence only" is enforced, not advised.
- **Artifact registry:** every branch and PR created in write mode is recorded per job and persisted. Cancel and merge phases operate only on registry entries. The app never deletes a branch it did not create — structurally.
- **Dry-run fidelity:** write mode re-runs the script live rather than replaying the recording (read-modify-write needs real intermediate state). The recorded plan is the reviewed preview; the guardrails are the safety. Divergence between plan and live run is logged and surfaced.
- **Cancellation:** user cancel aborts in-flight host calls; subsequent host calls throw `JobCancelled`; the JSC watchdog (`JSContextGroupSetExecutionTimeLimit`) hard-terminates scripts that ignore it or loop without calling the host.
- Per-repo failures isolate: a thrown error inside one repo's handling becomes a `job.error` row, not a dead run (house style: scripts wrap per-repo work in try/catch; the system prompt enforces this pattern).

## Example

User prompt:

```text
find repos that include a file at deploy/prod.yml where the key account_id has a value of "481832923858"
```

Generated check script (body):

```ts
async function main(): Promise<void> {
  const candidates = await gh.searchCode(
    `org:${job.params.org} path:deploy/prod.yml "${job.params.accountId}"`);
  job.progress(`${candidates.length} candidate repos`);

  for (const repo of candidates) {
    try {
      const text = await gh.getContent(repo, "deploy/prod.yml");
      if (text === null) { job.skip(repo, "file absent"); continue; }
      const doc = parse.yaml(text) as Record<string, unknown> | null;
      if (doc?.["account_id"] === job.params.accountId) {
        job.reportMatch(repo, { path: "deploy/prod.yml", excerpt: text });
      } else {
        job.skip(repo, "account_id differs or missing");
      }
    } catch (e) {
      job.error(repo, String(e));
    }
  }
}
```

Candidate search via the API, deterministic verification via fetched content — the v1 execution model, expressed as reviewable code instead of schema.

## AI Integration

- `LLMClient` abstraction as in v1, but it produces scripts:

```swift
protocol LLMClient {
    func makeScript(phase: JobPhase, prompt: String, context: JobContext) async throws -> ScriptSource
    func reviseScript(_ script: ScriptSource, diagnostics: [Diagnostic]) async throws -> ScriptSource
}
final class AnthropicClient: LLMClient
```

- The system prompt contains: the full `bulkgh.d.ts`, the house rules distilled from dev-handbook (dry-run thinking, canary-first, idempotent branch/PR naming, skip reasons, per-repo try/catch, progress reporting), and few-shot **recipes** — the Dependabot-sync, workflow-migration, and UAT-incident patterns translated to TypeScript. Recipes also appear in the UI as "new job from recipe" starting points.
- Type-check or runtime failures feed `reviseScript` for an automatic regeneration round-trip, always returning to user review.
- Provider stays behind the protocol (Anthropic first; default model hard-coded initially — pick the current recommended model at implementation time). API key in Keychain. Test-connection button.
- The AI never: holds credentials, triggers writes (only armed handles write, and arming is a native UI act), or treats search snippets as proof (enforced by `reportMatch`).
- Later phases may add an `ai.rewrite(content, instruction)` host capability for semantic per-file edits that pure code transforms can't express — it slots in as one more capability with dry-run review, not a schema change. Off by default. If repo file contents are ever sent to the LLM this way, treat them as untrusted input in the prompt.

## Validation Pipeline

1. **Type-check:** bundle the TypeScript compiler (pure JS) as a resource; run it in a secondary `JSContext` off the main thread against `bulkgh.d.ts` + the script. Diagnostics map to editor annotations.
2. **Transpile:** TS → JS via the same bundled compiler.
3. **Lint pass (cheap, Swift-side):** forbid `eval`/`Function` constructor, enormous literals, missing `meta`/`main`.
4. **Evaluate** in the phase-appropriate context.

Early spike required: tsc-inside-JSC latency and memory on representative scripts. Acceptable: a few seconds on first check. Fallback if not: transpile-only plus runtime validation of host-call shapes (weaker pre-run checking; does not change the architecture).

## Native macOS UX

Follow current macOS Human Interface Guidelines. SwiftUI app lifecycle, `NavigationSplitView`, native toolbar, sheets, alerts, menus, progress indicators. No web views.

Main window:

- **Sidebar:** organisations; current job with its phases (check / review / update / merge as steps with status); recent jobs; recipes. Later: history.
- **Middle pane, per phase:**
  - Script view: native code editor with TypeScript syntax highlighting (TreeSitter via SwiftTreeSitter is a candidate), inline diagnostics, param form rendered from `meta.params`, Generate / Re-check / Run controls.
  - Results table: repository rows with status, match evidence count, archived/private flags, default branch, skip reason, PR state — streaming in as the script runs.
  - Console: live `job.progress`/`job.log` output and per-repo events (the native equivalent of the scripts' progress dots).
- **Detail pane:** matching file preview with highlighted evidence and parsed-match explanation; for dry runs, the per-repo execution plan and native before/after diff (computed Swift-side); later, PR state and links.

Click-through links open GitHub in the browser: repo, file at branch/path, branch, commit, PR.

App icon: proper `.appiconset`; communicates repo search/bulk operations without trademark-sensitive GitHub logo copying.

State: save on quit; restore current job, prompt, scripts, params, results, selection, and settings. Run history and audit data stored locally.

## Settings

Native Settings window from phase 1.

### GitHub

- Organisation, defaulting to `geome`.
- GitHub web host, defaulting to `https://github.com`.
- GitHub API host, defaulting to `https://api.github.com`.
- Personal access token in Keychain; test-connection button.
- Token scope guidance: phase 1 read-only search needs metadata and content read; later phases need write for branches, commits, PRs, merges.
- Default branch behavior: repository default branch unless overridden.

### AI

- Provider hard-coded to Anthropic initially, behind the extensible `LLMClient` protocol.
- Model default hard-coded for first implementation.
- API key in Keychain; test-connection button.
- Phase 1 capability: check-script generation only.

### Behavior

- Dry-run default for any update-capable workflow (structural; this setting only controls UI emphasis).
- Max concurrent repository operations (enforced host-side).
- Rate-limit behavior: pause/retry/stop.
- Script execution time limit (watchdog).
- Confirm before opening PRs; confirm before merge; confirm before cancel/delete.
- Save run history on quit.

Secrets: GitHub and LLM credentials in Keychain only. Never in saved jobs, scripts, logs, crash reports, generated prompts, or source control. Apple Developer credentials for release builds arrive later as GitHub Actions secrets.

## Update Workflow - Later Phase

1. Run a check; review verified matches.
2. Enter update prompt (and PR title/body, which become `meta.params`).
3. LLM generates the update script; type-check; review/edit.
4. Dry run against the recording handle — per-repo execution plans and diffs.
5. User reviews plans, selects repos to apply (canary-first encouraged by the UI: apply to one, inspect the real PR, then widen).
6. User arms write mode (explicit confirmation).
7. Script re-runs against the guarded live handle for selected repos: branches, commits, PRs. Artifact registry records everything created.
8. App pauses for manual verification; PR links in the detail pane.
9. User approves selected PRs.
10. Merge phase script squash-merges approved PRs whose head SHA still matches expectations; deletes job branches.
11. Cancel action (job-level, confirmed): close registry PRs, delete registry branches, record outcomes.

Idempotency: predictable job-prefixed branch names; re-runs detect existing branches/PRs (`already up to date`, `branch exists`, `PR exists` states) and resume rather than duplicate.

### Worked example for the update phases

First update campaign to implement against (check phase already ships as the
`find_string_in_path` recipe, and the demo fixtures encode both cases):

- Find: repos where a file under `deploy/` contains
  `ec2-shell-prod-eu-west-1-keypair-1`.
- Update: delete the line containing that string from each matching file.
- Proviso: matching files may be YAML or JSON. In JSON, if the removed
  key-value pair is the last member of its object, the now-dangling comma at
  the end of the preceding line must be removed too. This argues for
  format-aware line surgery (delete line, then repair the neighbour) rather
  than parse–modify–serialise, which would destroy formatting elsewhere in
  the file — decide during phase 3 design and encode the choice as a house
  rule for update scripts.

Repository/job states (unchanged from v1):

- candidate
- verified match
- skipped
- already up to date
- branch exists
- PR exists
- PR raised
- blocked
- conflicted
- approved
- merged
- cancelled

## Persistence

Store locally (SwiftData if the deployment target allows; SQLite if more control is needed):

- Settings, minus secrets.
- Jobs: prompt, phase, scripts (source + host-API version + edit history), resolved params.
- Results: candidates, verified matches, file evidence, skip/error reasons.
- Execution plans from dry runs.
- Artifact registry (branches/PRs created, per job).
- Audit events: every effectful host call with arguments, outcome, and timestamp.
- Run status for resume.

## Testing

The capability-handle design makes generated scripts testable:

- **Fixture handle:** the same script runs against canned fixture data with no network — this is also the offline development mode while the network is unreliable.
- **Golden scripts:** the recipe library doubles as integration tests (recipe script + fixtures → expected matches/plans).
- **Contract tests** for the host bridge: every `bulkgh.d.ts` member exists, promises resolve/reject correctly, guardrails refuse out-of-policy calls (non-prefixed branch, unselected repo, missing precondition).
- Unit tests for plan/diff generation, parsers, and the validation pipeline.

## Release Workflow

GitHub Actions workflow for releases. Eventually: build, test, archive, code-sign with Developer ID, notarize, staple, package as `.dmg`/`.zip`, attach to a GitHub release. Phase 1 includes the workflow skeleton without real secrets. Likely secrets later: Apple team ID, signing certificate + password, App Store Connect API key ID / issuer ID / private key (for notarization tooling). Do not commit credentials.

## Risks and Open Questions

- **tsc-in-JSC spike** (phase 1, early): compile latency/memory. Fallback documented in Validation Pipeline.
- **Recording-handle fidelity:** synthesized responses may diverge from live behavior; mitigated by flagging synthetic values, logging divergence in write mode, and canary-first rollout.
- **Long-running runs:** org-wide scans are minutes-long; the console/results streaming and cancellation need to feel native and responsive from phase 1.
- **JS stdlib gaps:** YAML/TOML and diffing come from the host; resist letting the host API grow ad hoc — additions go through the same review as any contract change (consider ADRs for surface growth).
- **Prompt injection via repo content:** not applicable while the LLM only writes scripts from user prompts; becomes relevant if `ai.rewrite` ships — treat fetched file content as untrusted prompt input then.

## Implementation Phases

### Phase 1 - Native Read-Only Script Workbench

- Xcode project scaffold, app icon, SwiftUI shell.
- Settings window; Keychain storage for GitHub token and Anthropic key.
- Core models: settings, jobs, scripts, results, evidence, audit events.
- JSC execution harness: context-per-run, read-only handle, promise bridging, watchdog, cancellation.
- `bulkgh.d.ts` v1 (read surface + `job` + `parse`).
- Validation pipeline incl. tsc-in-JSC spike.
- Script editor with diagnostics + param form; console; results browser with GitHub links.
- Mock fixture handle and canned mock LLM for offline development.
- Anthropic check-script generation behind `LLMClient` (enable when network is stable).
- Persistence and restore-on-launch.
- Tests: host-bridge contract, golden recipe scripts vs fixtures, validation pipeline.
- GitHub Actions build/release skeleton.

### Phase 2 - History, Recipes, Richer Reads

- Saved jobs, run history, comparison between runs, export results.
- Recipe library UI ("new job from recipe") seeded from dev-handbook patterns.
- Additional read capabilities as recipes demand (e.g. workflow-file queries) — via contract review.
- Better rate-limit handling and pacing telemetry.

### Phase 3 - Dry-Run Updates

- Update-script generation; recording handle; execution-plan model.
- Native per-repo diff review; repo selection for apply.
- No remote writes in this phase at all.

### Phase 4 - Write Mode and PR Creation

- Guarded live handle; arming flow; artifact registry.
- Branch/commit/PR creation; resume and idempotency states; PR links and status.

### Phase 5 - Guarded Merge and Cancel

- Approval queue; merge handle with expected-head-SHA preconditions; squash merge.
- Cancel flow: close registry PRs, delete registry branches only.
- Full audit trail UI.

## First Implementation Step When User Says Go

Start without live network dependency:

1. Scaffold the native Swift macOS project in `/Users/steve/Development/projects/bulkgithub`.
2. Add app icon assets.
3. Add core models for settings, jobs, scripts, results, matches, artifacts, and audit events.
4. Add Settings UI with Keychain-backed credential fields.
5. Build the JSC harness with the read-only handle and a fixture-backed `gh` implementation; land `bulkgh.d.ts` v1.
6. Run the tsc-in-JSC spike; wire the validation pipeline.
7. Build the script editor, console, and three-pane results UI against fixtures; include one golden recipe script.
8. Add mock `LLMClient`; add persistence and restore-on-launch.
9. Add tests (bridge contract, golden scripts, validation) and the GitHub Actions workflow skeleton.

Do not begin live GitHub or Anthropic calls until the user confirms network is stable and credentials are available.
