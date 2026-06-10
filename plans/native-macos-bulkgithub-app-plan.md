# Native macOS Bulk GitHub App - Initial Handoff Plan

> **Superseded (2026-06-10):** replaced by [native-macos-bulkgithub-app-plan-v2.md](native-macos-bulkgithub-app-plan-v2.md), which adopts an embedded-script architecture (LLM-generated TypeScript on JavaScriptCore) in place of the structured search/update plan schema described here. See [ADR 0001](../decisions/0001-javascriptcore-as-embedded-script-runtime.md) for the decision record. Retained for reference.

## Context

The goal is to build a native macOS app for working across GitHub repositories in an organisation. The app should let a user describe repository characteristics in natural language, have an AI agent turn that into a structured search plan, use the GitHub API to find and verify matching repositories, and show the results in a native browser-style interface.

Later phases should allow a matching set of repositories to be updated safely: generate dry-run diffs, create branches, raise PRs, pause for manual verification, squash-merge approved PRs, and cancel raised PRs by closing them and deleting their branches.

The app must be a native Swift macOS app. No JavaScript frontend.

The user's existing bulk-update workflow lives at:

```text
/Users/steve/Development/geome/dev-handbook/scripts/
```

That workflow should influence the product model: dry-run by default, canary/single-repo first, explicit write mode, clear skip reasons, idempotent branches and PRs, and guarded merge as a separate step.

Network is currently unreliable. Do not start live GitHub or LLM integration work until the user says to proceed.

## Product Shape

The app is best thought of as a "bulk repo workbench" rather than a chatbot.

Core modes:

1. Find repositories.
2. Review verified matches.
3. Later: generate update dry runs.
4. Later: create PRs.
5. Later: verify and squash-merge approved PRs.
6. Later: cancel a job by closing raised PRs and deleting branches.

Assume one active job at a time for the first implementation. Saved job documents and multiple concurrent jobs can come later unless they fall out naturally from the data model.

## Example Search

User prompt:

```text
find repos that include a file at deploy/prod.yml where the key account_id has a value of "481832923858"
```

AI should convert this into a structured, editable search plan:

```yaml
scope:
  organisation: geome
candidate_search:
  file_path: deploy/prod.yml
  terms:
    - "481832923858"
verify:
  file_path: deploy/prod.yml
  parser: yaml
  predicate:
    key: account_id
    equals: "481832923858"
```

Execution model:

1. Use GitHub search/API calls to find candidate repositories.
2. Fetch the relevant file from each candidate repository.
3. Parse and verify locally in Swift.
4. Mark exact matches separately from candidates, skips, and failures.

Important rule: GitHub search results are candidate evidence only. The app should perform deterministic verification before declaring a repository matched.

## Native macOS UX

Follow current macOS Human Interface Guidelines.

Suggested layout:

- SwiftUI app lifecycle.
- `NavigationSplitView` with a sidebar, repository list, and detail/inspector pane.
- Native toolbar actions.
- Native Settings window.
- Native tables/lists, sheets, alerts, menus, progress indicators, and inspectors.
- No embedded web app.

Main window:

- Sidebar:
  - Organisations.
  - Current job.
  - Saved searches or recent searches.
  - Later: update campaigns and history.
- Middle pane:
  - Repository rows with status, match count, archived/private flags, default branch, skip reason, PR state.
- Detail pane:
  - Matching file preview.
  - Highlighted evidence.
  - Parsed match explanation.
  - Later: native diff view and PR state.

Click-through links:

- Repository opens the GitHub repo in the browser.
- Matching file opens the GitHub file URL at the relevant branch/path.
- Later: branch, commit, and PR links should open directly in GitHub.

App icon:

- Create a proper `.appiconset` for the macOS app.
- The icon should communicate GitHub repository search/bulk operations without relying on trademark-sensitive GitHub logo copying.

State:

- Save app state on quit.
- Restore current job, prompt, structured plan, results, selected repo, and settings.
- Store run history/audit data locally.

## Settings

There should be a native macOS Settings window from phase 1.

Suggested panes:

### GitHub

- Organisation, defaulting to `geome`.
- GitHub web host, defaulting to `https://github.com`.
- GitHub API host, defaulting to `https://api.github.com`.
- Personal access token stored in Keychain.
- Test connection button.
- Token scope guidance:
  - Phase 1 read-only search needs repository metadata and content access.
  - Later update phases need write access for branches, commits, PRs, and merges.
- Default branch behavior: use repository default branch unless overridden.

### AI

- Provider initially hard-coded to Anthropic/Claude, but represented internally as an extensible provider.
- Model default can be hard-coded for the first implementation.
- API key stored in Keychain.
- Test connection button.
- Phase 1 capability: search-plan generation only.
- Later capability: update-plan and patch generation.

### Behavior

- Dry-run default for any update-capable workflow.
- Max concurrent repository checks.
- Rate-limit behavior: pause/retry/stop.
- Confirm before opening PRs.
- Confirm before cancelling PRs or deleting branches.
- Save run history on quit.

Secrets:

- Store GitHub and LLM credentials in Keychain.
- Do not store secrets in saved job files, logs, crash reports, generated plans, GitHub Actions config, or source control.
- Apple developer credentials for release builds should be supplied as GitHub Actions secrets later.

## AI Boundary

The AI should produce structured plans, not directly operate GitHub.

Use an abstraction similar to:

```swift
protocol LLMClient {
    func makeSearchPlan(from prompt: String, context: SearchContext) async throws -> SearchPlan
    func makeUpdatePlan(from prompt: String, matches: [RepoMatch]) async throws -> UpdatePlan
}
```

Phase 1 concrete implementation:

```swift
final class AnthropicClient: LLMClient
```

Future implementations could add OpenAI, local models, or manual-only structured query entry without disturbing GitHub execution.

AI outputs must be shown as structured, editable plans before execution. The app should validate plans before running them.

The AI should not:

- Merge PRs.
- Make remote changes without reviewed dry-run diffs.
- Treat GitHub search snippets as proof.
- Rewrite formatting-sensitive files unless the update strategy is explicit and reviewed.

## GitHub Integration

Use a GitHub client behind a protocol so phase 1 can be developed with mock/local fixtures while the network is unreliable.

Likely responsibilities:

- Search repositories/code for candidates.
- Fetch repository metadata.
- Fetch file contents.
- Build GitHub web URLs for repos/files/branches/PRs.
- Later: create branches, commits, PRs, merge PRs, close PRs, delete refs.

Use Swift `URLSession` and Swift concurrency.

The app should be rate-limit aware and cancellable.

## Search and Verification

Initial supported predicates should cover high-value repository characteristics:

- File exists at path.
- YAML key equals value.
- JSON key equals value.
- TOML key equals value.
- Text contains string or regex.
- GitHub Actions workflow uses a reusable workflow.

For the example, candidate search can look for a path and value, then verification fetches `deploy/prod.yml` and parses YAML locally.

Avoid relying on broad source rewriting or lossy parser round-tripping for phase 1. Search is read-only.

## Update Workflow - Later Phase

The update mode should be a separate, explicit workflow:

1. Run a search.
2. Review matching repositories.
3. Enter update prompt and PR title/body.
4. AI generates proposed per-repo patches.
5. App shows native dry-run diffs.
6. User selects repos to apply.
7. App creates branches.
8. App commits changes.
9. App opens PRs.
10. App pauses for manual verification.
11. User approves selected PRs.
12. App squash-merges only approved PRs whose state still matches expectations.

Every operation should be resumable and idempotent.

Repository/job states:

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

Cancel raised PRs:

- Provide a job-level cancel action.
- Confirm before remote changes.
- For each raised PR:
  - Close the PR.
  - Delete the branch/ref if safe.
  - Record outcome in audit history.
- Never delete a branch unless it is the branch this app created for the job.

## Persistence

For phase 1, store:

- Settings, minus secrets.
- Current job prompt.
- Structured search plan.
- Candidate repos.
- Verified matches.
- File evidence.
- Run status.
- Audit events.

SwiftData is a reasonable default if the deployment target allows it. SQLite is an alternative if more control is needed.

Credentials belong in Keychain, referenced by account/service identifiers only.

## Release Workflow

Include a GitHub Actions workflow for releases.

Eventually it should:

- Build the macOS app.
- Run tests.
- Archive the app.
- Code-sign with Apple Developer credentials supplied as GitHub Actions secrets.
- Notarize the app.
- Staple notarization.
- Package as a `.dmg` or `.zip`.
- Attach artifact to a GitHub release.

Phase 1 can include the workflow skeleton without real secrets. Do not commit credentials.

Likely secrets later:

- Apple Developer team ID.
- Signing certificate.
- Certificate password.
- App Store Connect API key ID.
- App Store Connect issuer ID.
- App Store Connect private key.

## Suggested Implementation Phases

### Phase 1 - Native Read-Only Search Workbench

- Xcode project scaffold.
- SwiftUI app shell.
- App icon.
- Settings window.
- Keychain storage for GitHub token and Anthropic API key.
- One active job persisted on quit.
- LLM abstraction and Anthropic search-plan implementation.
- GitHub client abstraction.
- Mock GitHub/LLM fixtures for development without network.
- Structured search plan display/editing.
- Candidate search and deterministic verification when network is available.
- Native repository/file result browser.
- GitHub web links for repos and files.
- Initial tests.
- GitHub Actions build/release skeleton.

### Phase 2 - Search History and Richer Matching

- Saved searches.
- Run history.
- Export results.
- More file parsers and predicates.
- Better rate-limit handling.
- Comparison between runs.

### Phase 3 - Dry-Run Updates

- Update prompt to structured update plan.
- Patch generation.
- Native per-repo diff review.
- No remote writes unless explicitly enabled.

### Phase 4 - PR Creation

- Branch creation.
- Commit creation.
- PR creation.
- Resume existing branches/PRs.
- PR links and status.

### Phase 5 - Guarded Merge and Cancel

- Manual approval queue.
- Expected head SHA checks.
- Squash merge.
- Close PR/delete branch cancellation flow.
- Full audit trail.

## First Implementation Step When User Says Go

Start without live network dependency:

1. Scaffold the native Swift macOS project in `/Users/steve/Development/projects/bulkgithub`.
2. Add app icon assets.
3. Add core models for settings, jobs, plans, repos, matches, and audit events.
4. Add Settings UI with Keychain-backed credential fields.
5. Add mock LLM and mock GitHub clients.
6. Build the main three-pane UI with fixture data.
7. Add persistence and restore-on-launch.
8. Add tests around plan validation and local verification.
9. Add GitHub Actions workflow skeleton.

Do not begin live GitHub or Anthropic calls until the user confirms network is stable and credentials are available.
