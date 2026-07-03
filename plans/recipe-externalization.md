# Recipe externalization — ship & interchange recipes without a rebuild

> This is the **bulkgithub worked example** of the portable strategy in
> [recipe-externalization-strategy.md](recipe-externalization-strategy.md). For a
> sibling project, start from the strategy doc (applicability checklist + binding
> table) and use this one for the concrete shape of each step.

**Goal.** Add new recipes (and let users swap recipes freely) without editing Swift
or recompiling catalog logic. Recipes stay plain text. Scope for this plan:
**Phase 0 → Phase 2** (no-rebuild delivery + free interchange). Phase 3
(over-the-air) is sketched but explicitly deferred behind the ADR 0001 XPC move.

## Core decision

Do **not** invent a YAML/JSON recipe format. A recipe already *is* a single
self-describing `.ts` file: every bundled recipe declares `const meta = { title,
phase, apiVersion, params }`, and the app already reads that meta at runtime
(`ValidationPipeline.extractMeta`, [ValidationPipeline.swift:96](../Sources/BulkGitHubKit/Validation/ValidationPipeline.swift)).
The only data not in the file is `prompt` + `icon` (the SF Symbol), which is
exactly why adding a recipe today needs a Swift edit to `RecipeCatalog.all`
([RecipeCatalog.swift:37](../Sources/BulkGitHubKit/RecipeCatalog.swift)).

**Format = keep `.ts`; extend `meta` with optional `prompt?` and `icon?`.** One
file = one complete, type-checked, reviewable, emailable recipe. No sidecar, no
front-matter, no new parser. (YAML earns its place only later, as a *pack index*
for a curated downloadable set — a distribution concern, not the recipe format.)

**Distribution = two pure-text channels:** built-in recipes stay bundled in the
`.app`; a user-writable drop folder + Import/Export gives true no-rebuild delivery
and free interchange.

## Spike result (measured 2026-06-30, M-series, this repo)

The loader path is **transpile (strip types) + extractMeta**, *not* full
`validate()`:

| Path | first file (incl. 1× compiler boot) | warm/file | all 13 cold |
|---|---|---|---|
| transpile + extractMeta (loader) | 164 ms | ~7.5 ms | **254 ms** |
| full `validate()` w/ type-check | 357 ms | — | **5.95 s** |

Conclusions that lock the design:
- The tsc-in-JSC boot is ~160 ms (the only real cost), not seconds-scale.
- Building the catalog by reading meta from all bundled recipes is ~250 ms cold,
  ~0 with an mtime cache. Acceptable at launch, off the main actor.
- **Never type-check at catalog-build time** — 6 s for 13 files, and it grows with
  user recipes. Type-check stays where it is: on load-into-editor / before run.

## Phase 0 — Enrich + reconcile the `.ts` meta (data only)

Reversible, no behavior change. Lands and is verified *before* anything is deleted.

1. Add optional `prompt?: string` and `icon?: string` to the `ScriptMeta`
   TypeScript interface ([bulkgh.d.ts:189](../Sources/BulkGitHubKit/Resources/bulkgh.d.ts))
   and the Swift `ScriptMeta` struct
   ([CoreModels.swift:318](../Sources/BulkGitHubKit/Models/CoreModels.swift)).
2. Read both in `extractMeta` (currently dropped on the floor at
   [ValidationPipeline.swift:121](../Sources/BulkGitHubKit/Validation/ValidationPipeline.swift)).
3. Backfill `prompt` + `icon` into all 13 bundled `.ts` metas from the values
   currently in `RecipeCatalog.all`.
4. **Reconcile titles.** All 13 `meta.title` values currently *diverge* from the
   Swift sidebar titles (e.g. meta says "Find repos where a YAML/JSON file sets a
   key to a value" vs sidebar "Find YAML key/value"). Rewrite the 13 `meta.title`
   to the short sidebar form so meta is authoritative for both the sidebar and the
   editor. An equivalence test (old Swift titles == new meta titles) is
   **mandatory**, or the sidebar silently relabels.
5. Convert the 3 untyped recipes (`cancel_job.ts`, `change_pr_body.ts`,
   `merge_approved_prs.ts`, which use `const meta = {…}`) to
   `const meta: ScriptMeta = {…}` so the contract is enforced uniformly — without
   the annotation, a misspelled new field is silently dropped.

**Effort:** S (~1 day). **Do not delete the Swift array in this phase.**

## Phase 1 — Enumerate the bundled dir; delete the Swift array (kills the recompile)

1. Add `ResourceLocator.bundledRecipeFiles()` to list `recipes/*.ts` under
   `resourcesRoot` ([ResourceLocator.swift:12](../Sources/BulkGitHubKit/ResourceLocator.swift)).
2. Build the catalog at runtime: for each file, read source → `transpile` →
   `extractMeta` → `Recipe(id: <filename-stem>, title, prompt, phase,
   systemImage: icon ?? phaseDefaultIcon, source: <inline file text>)`.
   - **Always carry `inlineSource`.** Do *not* rely on `Recipe.source`'s lazy
     `id → recipes/<id>.ts` fallback ([RecipeCatalog.swift:15](../Sources/BulkGitHubKit/RecipeCatalog.swift)),
     or a loaded recipe can read the wrong file when an external file shares a stem.
3. Make the catalog **model state, not a static.** `RecipeCatalog.all` is consumed
   at [MainView.swift:392](../Sources/BulkGitHub/Views/MainView.swift) and via
   `RecipeCatalog.recipe(id:)` in `AppModel.loadRecipe(named:)`
   ([AppModel.swift:754](../Sources/BulkGitHub/AppModel.swift)). It now does file
   I/O and needs `TypeScriptService`, so it cannot stay a static literal. Move it
   onto the model; keep `recipe(id:)` as a lookup over the loaded set. (Don't try
   to "preserve the static call sites" — commit to the refactor and rewrite the
   ~2 sites.)
4. Build off the main actor with a brief "loading recipes" state; **cache by
   path+mtime** so steady-state launches do ~0 work. Skip-and-log a malformed file
   (never blank the whole library).
5. Apply the existing execution-time watchdog (the one `ScriptEngine` installs) to
   `extractMeta`'s context — see Risks. Run extraction with a per-file timeout.
6. Replace the `count == 13 && !prompt.isEmpty` guard
   ([UpdatePhaseTests.swift:272](../Tests/BulkGitHubKitTests/UpdatePhaseTests.swift))
   with an **equivalence test**: the loaded catalog matches the pre-deletion
   array's ids/titles/phases/prompts/icons. Add a trimmed version of the spike's
   `coldBuild` check as a guardrail ("every bundled recipe yields extractable
   meta; build stays cheap").
7. **Only then delete the `RecipeCatalog.all` literal** — it is the sole copy of
   `prompt`/`icon` until Phase 0's backfill is verified.

**Effort:** M. The static→instance refactor + off-main build + meta-without-typecheck
path are the real work, not the enumeration.

**Unlocks:** ship a new built-in recipe by dropping a `.ts` — no Swift edit. (It
still rides an app update because it lives in the signed `.app`; the *author* no
longer touches Swift.) No new trust boundary.

## Phase 2 — User drop folder + Import/Export + unify user recipes on `.ts`

1. Also enumerate a user-writable dir (reuse `~/Library/Application
   Support/BulkGitHub/recipes/`) through the same scan/extract path; merge with
   bundled into the one sidebar list ([MainView.swift:390](../Sources/BulkGitHub/Views/MainView.swift)).
2. **Import recipe…** (`NSOpenPanel`) copies a chosen `.ts` in after validation;
   **Export…** (`NSSavePanel`) writes one out; add Reveal in Finder / Reload.
3. **Unify user storage on `.ts`** (your chosen direction). Migrate the existing
   `UserRecipe` JSON ([UserRecipeStore.swift](../Sources/BulkGitHubKit/Persistence/UserRecipeStore.swift))
   non-destructively: **migrate → verify the `.ts` round-trips → only then retire
   the `.json`** (back up, don't delete). Keep the `.json` authoritative until its
   `.ts` loads cleanly, so no recipe vanishes mid-migration.
   - Note the field gap: `.ts`/`meta` has no home for `UserRecipe.id` (UUID) or
     `createdAt`. Decide: synthesize `id` from filename + keep `createdAt` from
     filesystem mtime, *or* keep a tiny JSON sidecar only for those two fields.
   - Rename today edits a JSON field without touching source
     ([AppModel.swift:795](../Sources/BulkGitHub/AppModel.swift)). Under `.ts`-only,
     rename/save must rewrite `meta.title` *inside the user's reviewable script
     text* — confirm that's acceptable (open question below).
4. **Provenance.** Ship a "from file — review before running" badge in the same
   change as Import; a dropped recipe must not look app-endorsed. Add a one-line
   note to ADR 0001 consequences that file-import is now a supported path.
5. **id precedence.** A colleague emailing you the bundled `find_yaml_key_value.ts`
   is likely, not an edge case. Rule: user file *shadows* the bundled one, shown
   with a visible "overrides built-in" indicator. Keep the bundled root read-only
   (don't seed it into the writable dir — avoids stale copies shadowing updated
   built-ins; editing a built-in = save-as-user-copy).
6. **Validate untrusted meta** (type-check covers shape, not validity —
   `icon: "made.up"` and `prompt: ""` type-check clean): validate `meta.icon` via
   `NSImage(systemSymbolName:)` with a per-phase default fallback; gate
   `meta.apiVersion` against a host max and surface "requires a newer BulkGitHub"
   as a distinct friendly diagnostic (list-but-disable), not a wall of type errors.

**Effort:** M–L.

**Unlocks:** true zero-app-update delivery + free interchange (the second half of
the goal). Does **not** cross ADR 0001's third-party trigger — dropped recipes
stay inert until human review + run, same as pasting into the editor.

## Phase 3 — Over-the-air / curated catalog (DEFERRED)

Background fetch writes `.ts` into a managed subfolder reusing the Phase 2
scan/validate path; optional signed/notarized packs with a "verified publisher"
badge; zip-slip/path-traversal defense on extraction. **Trigger/prerequisite:**
auto-fetching *unreviewed* third-party recipes is ADR 0001's literal revisit
condition — do the JSC-in-XPC-helper isolation **before** this, not after.

## Risks & mitigations

- **Scan-time code execution with no watchdog (most important).** `extractMeta`
  evaluates the *full* transpiled script body at top level
  ([ValidationPipeline.swift:104](../Sources/BulkGitHubKit/Validation/ValidationPipeline.swift))
  in a context with **no execution-time limit** (the watchdog is only wired into
  `ScriptEngine`). A Finder-dropped `.ts` with a top-level infinite loop / alloc
  bomb would hang catalog construction *at launch, before any review*. The
  "declarations only at top level" rule is a comment, not enforced; `ScriptLinter`
  bans only `eval`/`new Function`/`import`/`export`/`require`. → Apply the
  execution-time watchdog to the extract context; run off-main with a per-file
  timeout; consider a lint rule rejecting top-level side effects for imported files.
- **Deleting the Swift array deletes the only copy of `prompt`/`icon`.** → Phase 0
  lands + is verified before Phase 1 deletes; never combine in one commit.
- **id collision / bundled-source shadowing.** → Always set `inlineSource`; explicit
  user-shadows-bundled precedence, visibly flagged.
- **User-JSON migration could lose a recipe.** → migrate-then-verify-then-rename;
  `.json` stays authoritative until `.ts` loads clean; back up rather than delete;
  synthesize a meta block if a legacy source lacks one.
- **Untrusted icon / apiVersion skew.** → validate icon via SF Symbol lookup +
  default; gate apiVersion; friendly "needs newer app" diagnostic.

## Open questions

- Acceptable for a cosmetic rename to mutate `meta.title` inside the user's `.ts`?
  If not, keep a tiny JSON sidecar for mutable display fields and treat `.ts` as
  the canonical *logic* + export artifact.
- Persistent override of a bundled recipe wanted, or is save-as-user-copy enough?
  (Decides whether the bundled root stays strictly read-only — recommended.)
- Newer-`apiVersion` recipes: hide, or list-but-disable with a note? (Unifying on
  files makes cross-version interchange first-class.)
