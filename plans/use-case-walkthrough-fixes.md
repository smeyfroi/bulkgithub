# Use-Case Walkthrough — Issues & Fix Plan (2026-06-17)

Notes taken from a real-life run-through of the app, then grounded against the
code via investigation. Each item lists the symptom, the **grounded** root cause
(file:line), and a proposed fix with risk/effort. Several initial assumptions
were corrected by reading the code — flagged with **[reframed]**.

Stack: Swift 6 / SwiftUI macOS app; GitHub via `URLSession`; LLM-generated TS on
JavaScriptCore. Concurrency: `AsyncSemaphore`, default **8** concurrent host
calls (`CoreModels.swift:410`), JS runs single-threaded on a serial `vmQueue`.

---

## Workstream A — Quick UI / wording wins (low risk)

### Issue 2 — Fresh install should default to **live**, not fixture
- Root cause: `Settings.useFixtureGitHub` defaults to `true` — `CoreModels.swift:409`.
- Returning users are safe: settings load from `state.json` (`AppStateStore`), so
  only the no-saved-state default is affected.
- **Fix:** change default to `false`. ~1 line. **Low risk.**
- **DONE:** flipped `useFixtureGitHub` AND (per decision) `useMockLLM` to `false` — fresh
  installs are fully live (model + GitHub); state.json still overrides for returning users.

### Issue 11 — Rename "Merge" step → "Complete"
- **The phase is NOT always a merge.** It is script-driven (see ADR 0002,
  *merge-phase stays script-driven*): a script may squash-merge, cancel/close PRs +
  delete job branches, or any other finalizing action it decides. "Complete" is the
  right *action-neutral* name; "Merge" is a misnomer for the cancel/other cases.
- `JobPhase` enum case `merge` has `rawValue "merge"` used as a **persisted JSON key**
  (`resultsByPhase["merge"]`, etc.) — `CoreModels.swift:135-138`. **Keep the case/rawValue**
  for persistence; it's just an internal id now, not a claim about the action.
- Display-only sites to change — and these must become **action-neutral**, not say "merge":
  - `displayName` → `CoreModels.swift:147` ("Complete")
  - `MainView.swift:292` (stage label "Complete"); reconsider the merge-specific
    `systemImage: "arrow.triangle.merge"` since the action may be a cancel.
  - `ResultsPane.swift:122` — the per-row status **column is labeled "Merge"** but may
    show a cancel/close result → rename to "Complete" (or "Result"/"Outcome").
  - `BulkGitHubApp.swift:80` (menu), `ScriptPane.swift:115` (placeholder already mentions
    "merge or cancel" — keep generic), `MainView.swift:228` (apply-sheet wording —
    currently assumes merging; make it action-neutral, e.g. "runs the reviewed action on
    the PRs in this job's registry").
- **Fix:** keep `rawValue`; change the display strings to action-neutral copy; review the
  merge-specific icon. **Low risk, mechanical** — but copy review is the substance, not just
  a find/replace of "Merge"→"Complete".

### Issue 1 — Find step "AI" field doesn't wrap long unbroken words
- `ScriptPane.swift:25-35`: `TextField(..., axis: .vertical).lineLimit(2...6)`,
  `.textFieldStyle(.plain)`, inside `HStack(alignment: .firstTextBaseline)`.
- SwiftUI `TextField` wraps at word boundaries but a single very long token
  (URL/identifier) won't char-break, and `.plain` + unconstrained HStack width lets
  it overflow.
- **Fix:** give the field a bounded width (`.frame(maxWidth: .infinity)` within a
  constrained container) so wrapping engages; verify with a long-token paste.
  Single-token char-breaking is a SwiftUI limitation — accept or revisit if needed.
- **Low risk; needs a quick visual verify.**

### Issue 16 — Sort tables by clicking column headers
- Three SwiftUI `Table`s in `ResultsPane.swift`, all using **closure-only**
  `TableColumn`s (not sortable): Find/check `model.results` (`:176`, type `RepoResult`),
  Update `model.updateRows` (`:230`, `AppModel.UpdateRow`), Merge `model.mergeRows`
  (`:108`, `AppModel.MergeRow`). 15 columns total.
- **Fix per table:** add `@State sortOrder: [KeyPathComparator<RowType>]`, pass
  `sortOrder: $sortOrder` to `Table(...)`, convert the meaningful columns to
  value-based `TableColumn("…", value: \.keyPath) { … }`, and sort the array with
  `.sorted(using: sortOrder)` before passing it in (arrays are already computed/filtered).
- **Comparator work:** `RepoStatus` (Status/Find/Update/Merge columns) isn't `Comparable` —
  add a sort key (rawValue or an explicit phase-ordering). Repository → `repo.fullName`,
  Branch → `repo.defaultBranch`, PR → `row.number` are straightforward. Toggle columns
  (Approved/Apply) and free-text Detail: skip or low-priority.
- **Low risk, slightly more than a one-liner** (3 tables + enum comparator).

---

## Workstream B — PR body control (Issues 3, 7, 9 — one coherent cluster)

### Issue 7 — Created PR body uses script text, not the user's field **[reframed]**
- Not literally hard-coded in Swift. The user's `prBody` only reaches the script if
  the generated script **declared `prBody` in its `meta.params`**:
  `AppModel.swift:291-299` gates the override on `params["prBody"] != nil`.
- If the LLM bakes the body as a string literal in `createPR(...)` or omits the
  `prBody` param, the user's typed text is silently dropped — exactly the reported
  "hard-coded text from the script."
- Prompt does say "Use exactly this PR description" (`AppModel.swift:835-836`), but
  that's advisory to the LLM, not enforced. `createPR` body flows from the script's
  `opts.body` (`HostBindings.swift:461`) → GitHub (`LiveGitHubClient.swift:319`).
- **Fix (host-authoritative):** when the user provides title/body, make the host the
  source of truth — inject unconditionally (drop the `!= nil` gate) **and/or** have
  the `createPR` capability override body/title with the user-provided values when
  present, regardless of what the script passes. Mirrors the host-authoritative
  pattern already used for evidence highlighting. **Medium risk** (touches the write path).

### Issue 3 — Make PR title & description mandatory + LLM-pre-populated **[DECIDED]**
- Today they are **optional by design**: `PullRequestFields` (`ScriptPane.swift:276-303`)
  has plain `TextField`s, no required marker, and the caption says
  *"left empty, both are autogenerated."*
- `createPR` requires title+body at runtime (`HostBindings.swift:295-299`), but empty
  fields trigger LLM autogeneration rather than a block.
- **DECISION (2026-06-17):** fields are **mandatory** (marked required; Run disabled
  if either is empty) **and pre-populated by the LLM** at generation time so they're
  never blank. User can edit; whatever's in the field is used verbatim
  (host-authoritative, see Issue 7).
- **Implementation implication:** the title/body must become **outputs of script
  generation surfaced into the editable UI fields**, not values the script computes at
  runtime or bakes in. The generation prompt must emit a suggested PR title + body
  (e.g., a dedicated `pr-meta` block) that `parseGeneration` extracts and writes into
  `prTitle`/`prBody`; the field values then flow host-authoritative into `createPR`.
  This unifies #3 + #7. **Medium effort** (generation contract + parse + populate + write path).

### Issue 9 — Add "edit PR body after open" capability (feature)
- Full surface mapped (template = `createPR`/`mergePR`):
  - Protocol: `GitHubClient.swift:59-60`
  - Live: `LiveGitHubClient.swift` after :325 — `PATCH /repos/{repo}/pulls/{number}` `{body}`
  - Fixture: `FixtureGitHubClient.swift` after :270
  - Planned action: `CoreModels.swift:276-302` add `case editPR(number, body)` + summary
  - JS binding: `HostBindings.swift` merge surface (~:686, after `closePR`)
  - Type decl the LLM sees: `bulkgh.merge.d.ts`
- **DECISION:** which phase exposes it (Complete phase acting on registry PRs is the
  natural home; possibly Update too). Recommend: Complete phase, registry-scoped, with
  the same approval/registry guards as `mergePR`. **Medium effort.**

---

## Workstream C — Quota display fix

### Issue 5 — GitHub API quota display jumps around **[confirmed]**
- `RateLimitMonitor.update(from:)` writes `remaining/limit/reset` **unconditionally**,
  no ordering guard — `RateLimitMonitor.swift:24-26`. Called on **every** response
  (`LiveGitHubClient.swift:65`). With 8 concurrent calls, out-of-order arrival lets a
  stale (higher) `remaining` overwrite a fresher (lower) one.
- **Fix v1 (shipped, then found buggy live):** within the same reset window, only accept a
  `remaining` ≤ current (track the min); reset to new value when `x-ratelimit-reset` advances.
- **LIVE BUG (found scanning 235 repos):** gauge froze at `4994/5000` while the real `core`
  remaining had dropped to `4765`. Root cause: GitHub has **independent quota pools** (core,
  search, graphql, code_search, …) each with its **own** reset timestamp (verified via
  `/rate_limit`: graphql resets +135s, scim/audit_log ~+1h vs core). v1 used a single shared
  bucket, so a later-resetting pool's response latched `resetAt` forward — after which every
  `core` response read as a "stale older window" and was dropped, freezing the gauge. The guard
  conflated *different pool* with *older window*.
- **Fix v2 (shipped, STILL froze):** bucket by `x-ratelimit-resource`, guard per pool. Re-tested
  live: gauge still froze (at 4999, then 4983). Per-pool wasn't enough.
- **v2 LIVE DIAGNOSIS (instrumented `update()`, logged every header):** within the **single
  `core` pool**, GitHub returned **two different reset timestamps** — first readings `…374`,
  the rest `…202` (172s earlier). GitHub's limiter is distributed; **API replicas disagree on
  the window boundary by minutes**, so reset is non-monotonic *even within one pool*. v1/v2 both
  keyed staleness on reset comparison (`r < cur → drop`), so the later-reset early readings
  latched `resetAt` and every real `…202` reading was dropped. **Reset timestamp is not a valid
  ordering signal at all.**
- **Fix v3 (shipped):** within a pool, keep the **lowest** remaining (it only falls as the
  window is consumed) and accept a **rise only once the reset time has actually elapsed**
  (real rollover, via an injectable clock) — no cross-response reset comparison. Survives both
  out-of-order jitter (original bug) and replica reset-skew (freeze). Tests: `resetSkewDoesNotFreeze`
  (reproduces the live log), `rolloverRaisesQuota`, `keepsLowestWithinWindow`, + the two pool tests.
- **Lesson: three wrong fixes because the bug only manifested against real, distributed GitHub
  traffic. Unit tests and a static audit could not surface non-monotonic resets; live
  instrumentation (logging actual headers) was what cracked it. Verify networking fixes live.**

---

## Workstream D — Phase / repo-set carry-forward (Issues 4, 6) + idempotency answer (10)

### Issue 6 — Skipped repos reappear in Update **[reframed — script-contract, not engine bug]**
- Update doesn't auto-receive Find's filtered set. Generated Update scripts pick one of:
  - **Strategy A:** read carried state via `job.readState()` (skipped repos never appear) —
    state carried at `AppModel.swift:1040`.
  - **Strategy B:** re-enumerate ALL org repos via `gh.listOrgRepos()`
    (`HostBindings.swift:78-87`) and re-filter. If the LLM picks B, Find-skipped repos
    reappear.
- Root cause: generated Update scripts don't reliably carry the Find selection forward.

### Issue 4 — Update slow for skipped repos **[reframed — same root cause as 6]**
- Under Strategy B, each repo pays `gh.listFiles()` (`HostBindings.swift:151-166`) +
  `gh.getContent()` per file **before** `job.skip()` is reached
  (see `recipes/remove_line_with_string.ts:96,102-108`). That's the slowness.
- **Fix (shared with Issue 6):** make Find reliably persist its selected set and make
  Update consume it by default and skip-without-network for repos not in it. Levers:
  (1) strengthen the Update prompt + recipes to always carry state; (2) consider a
  first-class engine mechanism so the Update phase defaults to the Find selection
  rather than relying on LLM discipline. **Largest/most architectural item — needs design.**

### Issue 10 — Re-entering Update after PRs raised **[answered — mostly fine by design]**
- Idempotent with auto-recovery: `HostBindings.swift:479-509` →
  **RESUME** (job's own open PR → return it, skip create),
  **RECONCILE** (job-created branch, PR not in registry → adopt),
  **HALT** (foreign PR exists → `prExists`, no writes).
- The old createPR-409 false-positive is fixed: `listPRs` head filter now sends
  `owner:branch` (`LiveGitHubClient.swift:240-243`) + client-side exact filter.
- **No code fix required** beyond Issue 6 (re-enumeration). Worth a regression test.

---

## Workstream E — Capability-gap script preservation

### Issue 8 — Capability-error text clobbered by default/previous script **[confirmed]**
- During streaming, `liveScript` extracts text inside the ``` fence — including the
  capability-gap **report** — into `scriptText` (`AppModel.swift:844-850`;
  `LLMClient.swift:206-215`), so the user briefly sees it.
- Then `parseGeneration` detects `.capabilityGap` and runs
  `scriptText = previousScript` (`AppModel.swift:868`), clobbering the report; the
  report goes only to the log via `surfaceCapabilityGap`.
- **Fix:** on `.capabilityGap`, keep the report visible where the user is looking —
  set `scriptText` to the report (e.g., as a commented block) or a dedicated error
  banner, instead of restoring `previousScript`. **Low–medium risk.**
  - **DECISION:** raw report in the script field vs. a dedicated non-editor error area.

---

## Workstream F — Merge robustness (Issues 13, 14, 15) + concurrency model (12)

### Issue 12 — Concurrency model **[answered — context]**
- `AsyncSemaphore` (`HostBindings.swift:19-33`), default **8** concurrent host calls
  (`CoreModels.swift:410`, user-tunable). All phases fan out under it; JS settles on a
  serial `vmQueue` (`ScriptEngine.swift:150`); shared state guarded by `NSLock`.

### Issue 13 — Merge calls per repo & 502s **[answered]**
- Per repo: getPR drift check (`HostBindings.swift:621`) + mergePR
  (`:635`) + deleteBranch (`:707`) = **3 happy-path**, up to ~7 with retries.
- 5xx retry exists: 3 attempts, **linear** backoff 1/2/3s, re-check via
  `mergedCommitSha()` to avoid double-merge — `LiveGitHubClient.swift:336-372`. 502 IS
  retried.
- **Fix options:** exponential backoff + jitter; consider lowering merge-phase
  concurrency to reduce 5xx amplification; the 3 calls are each necessary.

### Issue 14 — Did restart clear the 502s? **[answered — likely coincidence]**
- 502 is a GitHub-side gateway error → restart shouldn't fix the root cause
  (transient blip that would clear anyway). **But** the app uses `URLSession.shared`
  (`LiveGitHubClient.swift:26`) with no explicit pool config; the connection pool lives
  for the app's lifetime and only flushes on restart — so a wedged HTTP/2 connection
  *could* contribute (low confidence, unproven).
- **Cheap hardening:** use a dedicated `URLSession` with explicit config; optionally
  reset the session on repeated 5xx. **Low risk; addresses the hypothesis cheaply.**

### Issue 15 — Merge-conflict recovery **[answered — distinction is correct; recovery is thin]**
- Conflict (405 unmergeable) and head-moved (409) are correctly **not** retried —
  `isTransientMergeError` only treats 5xx/network as transient
  (`LiveGitHubClient.swift:386-392`). Head-moved halts the repo as `.conflicted` with a
  clear reason (`HostBindings.swift:616-625`). A true base conflict throws and halts
  that repo.
- Gap: no in-app per-repo recovery — the user must resolve upstream and re-run.
- **Fix options:** clear conflicted-status surfacing (mostly present) + optional
  per-repo "retry"/"update-branch-from-base" affordance. **Bigger; recommend deferring
  the affordance, confirm surfacing now.**

---

---

## Workstream G — App-wide resilient retry + completion notification (Issue 17)

### Issue 17 — Retry transient failures app-wide, with UI + notify-on-completion
- **Today:** `fetch()` (`LiveGitHubClient.swift:54`) is the single chokepoint for every
  GitHub call but does **not** retry 5xx (only rate-limit at :69-70). Merge has the only
  retry loop (`:336-372`). So every non-merge read/write fails hard on a 502 — the likely
  reason 502s feel pervasive. No notification infra (`UserNotifications` unused). No retry UI.
- **Goal:** retry transient failures (5xx + network, honor `retry-after`) broadly with
  generous, bounded backoff so the user can walk away; surface retrying state in the UI;
  post a local notification when a long-blocked run finally finishes.

Four components:
1. **Centralized retry at `fetch()`** — exponential backoff + jitter, honoring server
   `retry-after`, replacing/extending the merge-only loop. Subsumes #13/#14 backoff work.
2. **Retry budget for unattended runs** — "keep trying for up to N min / M attempts."
   Must stay cancellable (cancel path exists) and be reconciled with the **900s run
   timeout** (`ScriptEngine.swift`) — a long retry budget can exceed it; raise/scope the
   cap or budget within it.
3. **Retry UI** — surface "retrying… attempt k, next in Ns / waiting on GitHub" per repo
   or as a global banner. Extend the existing progress meter / audit channel (retry layer
   emits progress events).
4. **Completion notification** — net-new `UserNotifications` (UNUserNotificationCenter):
   request authorization, post a local notification when a run that hit retries completes
   (success or terminal). App is signed/notarized → local notifications are fine.

**CENTRAL SAFETY FORK (DR1) — reads vs writes:**
- **Reads (GET)** — idempotent, safe to retry freely.
- **Writes (POST/PATCH/PUT/DELETE)** — NOT inherently idempotent. A 502 that *actually
  succeeded* server-side would double-act on blind retry. Merge already solves this with a
  re-check (`mergedCommitSha`); `createPR` is guarded by its listPRs preflight + RESUME;
  `createBranch`/`putContent` have their own idempotency quirks (422 on existing ref, blob
  sha on update).
- **Decision:** (a) auto-retry **reads only** at the `fetch()` layer (simple, safe) and
  leave writes to existing engine-level idempotency/re-check; or (b) extend the merge-style
  re-check pattern to all writes for full coverage (more work, per-endpoint).
  → Recommend **(a) first**, layer in (b) per-endpoint as needed.

**Other decisions:**
- **DR2 — budget model:** fixed max attempts vs. time-budget ("try up to X min"); reconcile
  with the 900s run timeout.
- **DR3 — notify trigger:** always on completion / only when retries occurred / user setting;
  plus first-run authorization UX.

**Effort: large.** Its own round; subsumes the #13/#14 backoff work from Workstream F.

---

## Proposed sequencing

1. **Round 1 — quick wins (low risk):** Issues 2, 11, 5, 8, 1, 16.
   ✅ **DONE** — branch `round1-walkthrough-fixes`; build + 87 tests green (incl. new
   `RateLimitMonitorTests`). #2 expanded per decision: fresh installs default BOTH
   `useMockLLM` and `useFixtureGitHub` to live (returning users' saved prefs still win).
2. **Round 2 — PR body control:** Issues 7 + 3 + 9 (editPR).
   ✅ **DONE** — branch `round1-walkthrough-fixes`; build + 93 tests green (new:
   `PRBodyControlTests.overrideWins`, `MergePhaseTests.editPRFlow`).
   - **#7 host-authoritative:** `EngineConfiguration.prTitleOverride/prBodyOverride` threaded
     through `HostBindings` → `createPR` (dry-run + armed, shadowing `title`/`body`); set for
     `.update` in `runInternal`. `effectiveParams` now injects prTitle/prBody **unconditionally**
     (removed the `!= nil` gate) so staleness + `job.params` still work; the override is the
     authority.
   - **#3 mandatory + pre-populated:** `prFieldsComplete` gates the Run/Apply button (not
     Generate — must stay usable to draft); `PullRequestFields` marked required with an
     empty-state warning. House rule 14 tells the LLM to declare prTitle/prBody params;
     `performValidation` safety-net seeds them (from `meta.title` / a generic body) so the
     required fields are never blank.
   - **#9 editPR:** mirrors `closePR` (registry-scoped + conform, **no approval gate** — body
     edits are low-risk, divergence from the earlier "mergePR guards" rec). Added `body` to
     `PullRequestRef` (+ scriptValue + `bulkgh.d.ts` PR.body?), `PlannedAction.editPR`
     (+ `DetailPane` icon/preview), binding in `installMergeSurface`, decl in `bulkgh.merge.d.ts`.
3. **Round 3 — resilient retry + notifications (design-first):** Issue 17 (subsumes
   #13/#14 backoff), + dedicated `URLSession`, + #15 conflict surfacing.
   ✅ **DONE** — 6 chunks, build + 103 tests green: reads-retry (exp backoff+jitter at
   `fetch()`), guarded writes (per-endpoint re-check before re-issue), `RetryMonitor`→footer
   "Retrying…" line (polled mid-stall), completion notifications (`UNUserNotificationCenter`,
   gate: retried-or->60s AND backgrounded), dedicated ephemeral no-cache `URLSession` +
   "Reset GitHub Connection" menu item, and #15 (405/409 → per-repo `.conflicted` + badge
   warning icon). Deferred: update-branch capability, per-repo retry button, AnthropicClient
   session. NOTE: new app-target files need `xcodegen generate` before `make_app.sh`.
4. **Round 4 — carry-forward (design-first):** Issues 4/6, with a regression test for 10.
   ✅ **DONE** — chose first-class engine carry-forward (D4): a dry-run Update now scopes
   `configuration.targetRepos` to Find's matched repos (host-authoritative — a re-enumerating
   script can't resurrect skipped repos or waste calls on them); a canary still overrides; no
   Find/no matches = unscoped as before. #10 already covered by `ArmedRunTests.resumeRerun`;
   added `carryForwardScopesUpdateToMatches`. listOrgRepos audit "(canary target)" → "(scoped)".

---

## ✅ All four rounds shipped (branch `round1-walkthrough-fixes`, 104 tests green, NOT committed)

## Decisions
- **D1 (Issue 3) — DECIDED 2026-06-17:** PR fields mandatory **and** LLM-pre-populated
  into editable fields; values are host-authoritative. Unifies #3 + #7.
- **D2 (Issue 9) — DECIDED:** `editPR` in the Complete phase, registry-scoped + plan-conform,
  but **no approval/head-SHA gate** (mirrors `closePR`, not `mergePR` — a body edit doesn't
  touch code, so the approval gate would be overkill). Body-only (not title).
- **D3 (Issue 8) — DECIDED:** capability-gap report stays in the script field (per the
  original report).
- **D4 (Issue 4/6) — open, design-first:** prompt/recipe discipline vs. first-class
  engine carry-forward. Decide at Round 4.
