# Externalizing bundled script-artifacts — portable strategy

A project-agnostic guide for letting an app ship and interchange its bundled
script "recipes"/plugins **without a recompile**. Written for **near-clone
siblings** of bulkgithub: Swift + JavaScriptCore, self-describing TypeScript
script artifacts type-checked against a `.d.ts`, and a hardcoded Swift catalog.

> **Worked reference:** [recipe-externalization.md](recipe-externalization.md) is
> the concrete bulkgithub implementation this generalizes. When a step is vague
> here, read the equivalent section there for the exact shape — including the
> Phase 0 diff that has already shipped (build + 127 tests green).

## The strategy in one paragraph

Don't invent a serialization format (no YAML/JSON wrapper). The artifact is — or
cheaply becomes — self-describing; the only thing forcing a recompile is a
**hardcoded registry that duplicates metadata the artifact already carries**.
Make the in-artifact metadata the single source of truth, build the catalog by
**enumerating directories at runtime**, and ship/interchange artifacts as plain
files. Phase it so the recompile dies first (low risk, mostly already built),
then file import/interchange, then — only behind the trust boundary — over-the-air.

## Applicability checklist — run this FIRST, per project

Near-clones will answer "yes" to most of these, but **#3 is the linchpin** and
must be confirmed individually; the others shape scope.

1. **Is there a hardcoded registry/catalog that forces a rebuild to add an
   artifact?** (This is the thing you kill.)
2. **Does the artifact already carry structured metadata, or can it cheaply?**
   (The catalog-only fields must be small/data — title, description, icon — not
   logic.)
3. **TRUST LINCHPIN — is the artifact ALWAYS human-reviewed before it executes,
   never auto-run on load?**
   - **Yes →** loading/importing a file is as safe as pasting into the editor;
     Phases 0–2 cross **no new trust boundary**.
   - **No (artifacts auto-run on load) → STOP.** The risk calculus changes; you
     need execution isolation *before* file import, not after. Re-scope before
     proceeding.
4. **Is there a metadata-extraction mechanism already, and what does it cost at
   build time?** (You will measure this in Phase 1 — see the spike.)
5. **Is there an existing file-based user store to unify onto?** (Shapes Phase 2.)
6. **Is metadata duplicated between the registry and the artifact today?** (That
   duplication is what you collapse; expect drift — see Phase 0 reconciliation.)

If 1, 2, 3-yes, and 4 hold, the strategy fits.

## Binding table — fill in per sibling

Map each strategy role to the repo's concrete name. The bulkgithub column is the
worked example; copy this table into each sibling's own plan.

| Role | bulkgithub | Project A | Project B |
|---|---|---|---|
| Artifact file | recipe `.ts` (`meta` + `main()`) | | |
| In-artifact metadata block | `const meta` | | |
| Metadata type (Swift + `.d.ts`) | `ScriptMeta` / `interface ScriptMeta` | | |
| Metadata extractor | `ValidationPipeline.extractMeta` | | |
| Transpiler / type-checker | `TypeScriptService` (tsc-in-JSC) | | |
| Hardcoded catalog | `RecipeCatalog.all` + `Recipe` struct | | |
| Catalog consumers | `MainView` sidebar, `AppModel.loadRecipe` | | |
| Bundled artifact dir | `Resources/recipes/*.ts` via `ResourceLocator` | | |
| User / file store | `UserRecipeStore` (JSON per file) | | |
| Trust-model doc | ADR 0001 | | |
| Execution watchdog | JSC watchdog in `ScriptEngine` (absent in extractMeta) | | |
| Cutover guard test | `RecipeMetaCutoverTests` | | |
| Fields catalog-only today | `prompt`, `icon` | | |

## The phases (generalized)

### Phase 0 — Enrich + reconcile the metadata (data only, reversible)

- Add the catalog-only fields (your `prompt`/`icon` equivalents) as **optional**
  to the metadata type — *both* the Swift struct and the `.d.ts` interface — so
  every existing and in-flight artifact stays valid.
- Read the new fields in the extractor.
- **Backfill** every bundled artifact's metadata from the hardcoded catalog.
- **Reconcile divergence.** Check each field the catalog owns against the
  artifact's metadata — *especially the title*. (In bulkgithub all 13 titles
  diverged from the sidebar labels.) Add a **cutover equivalence test** asserting
  artifact-metadata == catalog-entry for every field. This test is the gate for
  Phase 1.
- **Normalize to the typed metadata form** so the contract is enforced uniformly
  (bulkgithub had 3 artifacts using untyped `const meta = {…}`, which silently
  drops a misspelled new field).
- **Do not delete the catalog yet.** Land this as its own verified commit.

### Phase 1 — Enumerate the bundled dir; delete the literal (kills the recompile)

- Add a directory enumerator for bundled artifacts.
- Build the catalog at runtime: per file → **cheap extract** (transpile / type-
  strip + read metadata), **NOT full type-check**. Map to your catalog entry, and
  **always carry the source inline** — do not rely on a lazy `id → path` resolver
  (that causes the shadowing bug in the risk list).
- **MEASURE FIRST (loader-cost spike).** Time the cheap path vs full validation
  across all bundled artifacts, cold and warm. Conclusions to reach: is eager
  launch-build acceptable, or do you need a cache? bulkgithub measured **254 ms
  cold** for the cheap path (incl. a 160 ms one-time compiler boot) vs **5.95 s**
  for full type-check across 13 → never type-check at build; cache by path+mtime;
  build off the main thread. **Your numbers will differ — measure them in that
  repo.**
- **Apply the execution watchdog to the extractor's context.** It very likely
  lacks one even though the main engine has it, because the extractor evaluates
  the full artifact body at top level. Add a per-file timeout too.
- **Move the catalog from a `static` to model/instance state** (it now does I/O);
  rewrite the consumers. Don't try to keep the static call sites.
- Swap any `count == N` guard for the equivalence test, then **delete the
  hardcoded literal** — separate commit, only after Phase 0 is verified (the
  literal is the only copy of the catalog-only fields until backfill lands).

### Phase 2 — User drop folder + import/export + unify the store

- Enumerate a user-writable dir through the **same** scan/extract path; merge into
  one list.
- **Import / Export** (open/save panel) that copies an artifact in/out after
  validation.
- **Unify the user store** onto the artifact format with a non-destructive
  *migrate → verify → rename* (keep the old store authoritative until the new
  form round-trips cleanly). Mind the field gap: identifiers/timestamps the old
  store carried may have no home in the artifact — decide synthesize vs sidecar.
- **Provenance** badge ("from file — review before running"); **id precedence**
  (user shadows bundled, visibly flagged); **validate untrusted metadata** (icon/
  symbol validity, `apiVersion` gate). Type-check validates *shape*, not
  *validity* — an invalid icon or empty description type-checks clean.

### Phase 3 — Over-the-air (DEFERRED, gated by the trust boundary)

Only if wanted. Auto-fetching *unreviewed* third-party artifacts is the trust-
model's revisit trigger — do the execution isolation (e.g. JSC-in-XPC) **first**.

## Transferable risk catalog

1. **Scan-time code execution with no watchdog** — catalog-build evaluates
   untrusted artifact bodies; the extractor's context often has no execution-time
   limit even when the main engine does. → Watchdog + per-file timeout, off-main.
2. **Deleting the registry deletes the only copy of catalog-only metadata** →
   enrich + verify (Phase 0) before delete (Phase 1); separate commits.
3. **id collision / source shadowing** — a lazy `id → path` resolver can make an
   external file read a bundled one. → Always carry source inline; explicit
   precedence.
4. **Migration data-loss** → migrate-then-verify-then-rename; keep the old store
   authoritative; back up, don't delete.
5. **Untrusted metadata** — type-check ≠ validation. → Validate icon/symbol
   validity and gate `apiVersion` at load, with a friendly "needs a newer app".
6. **Provenance over-trust** — an imported artifact looks identical to a bundled
   one. → Badge it.
7. **Build-time cost surprise** → measure before choosing eager vs cached loading.

## Adaptation workflow for a near-clone sibling

1. Copy the **binding table** above into the sibling's plan and fill it in
   (mostly path/name mapping).
2. Run the **applicability checklist** — confirm #3 (review-before-run) in that
   repo specifically.
3. Run the **loader-cost spike** in that repo (don't reuse bulkgithub's numbers).
4. Execute **Phase 0 → guard green → Phase 1 → Phase 2**, each as its own verified
   commit.
5. Diff each step against the bulkgithub worked example
   ([recipe-externalization.md](recipe-externalization.md)) for the concrete shape.
