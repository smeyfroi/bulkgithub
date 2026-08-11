# File parameters: adding a user-supplied file in an Update step

## The problem

An Update step is a prompt → LLM-generated TypeScript → `gh.putContent`. To add
a whole file (a CI workflow, a LICENSE, a config) the file's bytes must reach
that `putContent` call. Routing them through the LLM (pasted into the prompt,
re-emitted as a string literal) is fidelity-risky and token-expensive; storing
them in params breaks recipe sharing (params don't travel); URL references
breach the no-network sandbox promise.

## The design (Option B — reviewed 2026-08-11)

**A param whose key ends in `File` (case-sensitive) is a file parameter.** What
travels in a recipe is the EMPTY declaration — the requirement, not the bytes:

```typescript
params: { path: ".github/workflows/ci.yml", contentFile: "" }
```

- **Picker-only.** The app renders an "Attached files" row with a Choose…
  button (`NSOpenPanel`). Paths are never typed, never expanded from `~`/env,
  and never read from a recipe — validation rejects a `*File` param with a
  non-empty default, so a shared recipe cannot arrive pointing at a path on
  someone else's machine.
- **The script never sees the filesystem.** `job.file(key)` returns the exact
  bytes, host-resolved; `job.params[key]` carries the display NAME only (safe
  for commit messages). House rule 9 stays literally true.
- **Fail-closed resolution, host-side, pre-engine:** symlinks resolved, then a
  sensitive-location denylist on the REAL path (anything hidden directly under
  home — `~/.ssh`, `~/.aws`, `~/.netrc`, … — plus the entire `~/Library`
  subtree; TCC does not guard these), then a stat-before-read size check,
  strict UTF-8 (never lossy), and a 2 MB cap. Any failure refuses the whole
  run BEFORE any job state is touched — a refused run leaves the reviewed
  plan, results, and logs exactly as they were.
- **Snapshot at dry-run; armed replays the snapshot.** The dry run snapshots
  content + sha256 + provenance onto the Job. Armed/resume feeds the SNAPSHOT
  into `job.file` and commits the plan's `expectedAfter` — an approved plan
  survives the local file being edited, moved, or deleted. File-content drift
  (sha256 vs snapshot, recomputed at discrete moments and on every re-pick —
  no IO in computed vars) is **advisory only**: it composes into the
  staleness banner and the row caption but never blocks arming, because the
  armed run applies the reviewed bytes regardless. Script/param edits still
  invalidate arming as before.
- **Pick memory (Option B), machine-local:** recipe id → key → path lives in
  app state (`AppStateSnapshot.filePickMemory`), never in the `.ts`. Reopening
  a recipe re-attaches your last pick only if the file still exists and still
  passes the full checks; otherwise the field is blank and Run stays gated.
- **Review provenance:** a planned write whose content is byte-identical to an
  attached file is captioned with the file's name and size in the plan pane.
- **LLM contract** shipped in the same change: `job.file` declared in
  `bulkgh.d.ts`, house rule 9 amended, house rule 19 added (declare a `*File`
  param when the user supplies a file; new files need no prior `getContent`),
  and a bundled demonstrator recipe (`add_file.ts`).

## Deliberately cut

- **Relative-path recipe bundles** ("recipe ships with its file"): no anchor
  exists (a Job keeps no link to its source recipe file; the loader is flat
  and `.ts`-only), and it is the traversal/symlink attack surface. Rejected at
  validation to reserve the syntax.
- **Binary files:** the write path is String-typed end to end; base64 in a
  diff is unreviewable. UTF-8 text only, by construction.
- **URL/gist references:** breach the sandbox promise; the picker + snapshot
  covers the use case without the SSRF surface.

The `*File` + `job.file(key)` contract is source-agnostic: a host-managed
attachment store (self-contained recipe sharing, binary support, App-Store
sandboxing) can later back the same API without touching recipes or generated
scripts.

## Adversarial review (2026-08-11)

A 35-agent find→verify pass over the diff confirmed 19 distinct defects, all
fixed before merge. The notable ones: file-resolution aborts ran AFTER
runInternal's destructive state wipes (a refused run destroyed the reviewed
plan — resolution is now hoisted above every mutation); `pickFile` cleared the
staleness flag instead of recomputing it against the snapshot (a divergent
re-pick could silently arm old bytes); file staleness accidentally blocked
arming via `resultsAreStale` (now split: `planIsStale` gates, file drift
advises); house rules 14/19 contradicted each other on getContent-before-put
(now reconciled: fetch unless confirmed absent); the `*File` suffix collided
with natural repo-path param naming (rule 19 + the validation error now both
steer to `*Path`); the denylist missed non-dot credential stores under
`~/Library` (now the whole subtree); pick-memory prefill lacked supersede/phase
guards; ghost picks/snapshots survived param renames, data-source switches,
and recipe deletion (all pruned); `currentRecipeId` now persists on the Job.

## Touched

`FileParams.swift` (new), `CoreModels.swift` (Job fields), `ValidationPipeline`
(empty-default rule), `EngineConfiguration.resolvedFiles`, `HostBindings`
(`job.file`, armed write commits `expectedAfter`), `AppStateStore`
(`filePickMemory`), `AppModel` (picks, snapshots, resolution, staleness, pick
memory), `ScriptPane` (Attached-files card), `MainView` (Run gate),
`DetailPane` (provenance caption), `bulkgh.d.ts` / `bulkgh.update.d.ts` /
`LLMClient` house rules, `recipes/add_file.ts`, `FileParamTests.swift`.
