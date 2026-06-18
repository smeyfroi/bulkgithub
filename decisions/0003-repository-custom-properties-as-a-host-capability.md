# ADR 0003: Repository Custom Properties as a Host Capability (Read/Query + Write)

- **Status:** Accepted
- **Date:** 2026-06-17
- **Decision owner:** Steve
- **Input:** Scope-extension discussion (Claude, 2026-06-17). Builds on [ADR 0001](0001-javascriptcore-as-embedded-script-runtime.md) (JSC script host) and [ADR 0002](0002-merge-phase-stays-script-driven.md) (one execution model for every effect).

## Context

Every capability the app has so far operates on three things: repository **files** (`getContent`/`putContent`), **git refs** (`createBranch`/`getRef`), and **pull requests** (`listPRs`/`createPR`/`mergePR`/…). It has never read or written **repository metadata** — the `RepoRef` struct carries only the fields that arrive as a side effect of listing repos (name, default branch, archived, private). There are no bindings for topics, description, visibility, or custom properties.

A new class of campaign has been requested: **govern repos by metadata derived from their contents.** The motivating example —

> for all repos that contain `project.json`, set the custom property `ProjectType` to the value of the `type` key

— and its read counterpart —

> find repos where custom property `ProjectType` is `rails`

Both halves are natural fits for the existing architecture. The read half is a check-phase concern; the write half is an update-phase concern. The app already has the harder ingredient: check scripts routinely fetch and parse file contents to make decisions (see `find_yaml_key_value.ts`, `change_yaml_value.ts`). What is missing is a metadata surface.

### Topics vs. custom properties

GitHub offers two repo-tagging primitives, and only one fits the use case:

- **Topics** are flat, free-form string tags (`rails`, `internal-tool`), lowercase, up to 20 per repo, available on any repo with push access. They are *values only* — there is no name/value pairing. Expressing `ProjectType = rails` with topics requires faking it (`projecttype-rails`), which is not a queryable field and pollutes the public topic set.
- **Custom properties** are true name/value metadata, defined once at the **organisation** level (each property has a type: string, single-select, multi-select, or true/false, with optional allowed-values), then given a value per repo. They exist to drive governance — repository rulesets can target "all repos where `ProjectType = service`".

The requested feature is key/value (`ProjectType` → a value), so **custom properties is the correct primitive**. Topics are a different API surface and are deferred (see Revisit triggers).

### The read-strategy fork

GitHub exposes three ways to read property values, which trade off the same way the app's existing `searchCode` (fast, indexed, never proof) trades against `getContent` (authoritative):

1. **Authoritative, whole-org:** `GET /orgs/{org}/properties/values` returns every repo with its values, paginated. Real stored values, not an index.
2. **Authoritative, per-repo:** `GET /repos/{owner}/{repo}/properties/values`. Exact, one repo, N calls if used as the primary search.
3. **Indexed search:** the `props.<name>:<value>` qualifier in repository search (and the `repository_query` param on the org endpoint). Server-side filtered and fast, but **eventually consistent** — the same staleness class that produced the live-`listPRs` head-filter bug ("the mystery of the 23").

## Decision

**Add repository custom properties as a new host capability spanning two phases — query (check) and set (update) — under the same capability-mode and dry-run guardrails as every other effect. Reads are authoritative-first; the org bulk-values endpoint is the backbone for querying, not indexed search. Scope v1 to org-owned repos and to *setting values on already-defined properties* (values-only, not schema management).**

Key elements:

- **New read bindings (present on every handle):**
  - `gh.listOrgProperties()` — authoritative bulk read of repo → property values across the org (read strategy #1). Powers "find repos where `ProjectType = rails`": the script filters in JS against real values, with no staleness to defend against.
  - `gh.getProperties(repo)` — per-repo authoritative read (strategy #2), the sibling of `getContent`; used to verify a single repo and to feed dry-run diffs / idempotency.
  - `gh.listPropertyDefs()` — the org's property schema (name, type, allowed values), so a script can validate a value before attempting to write it.
- **New write binding (absent on read-only handles; recorded on dry-run; guarded on live):**
  - `gh.setProperties(repo, values)` — set/clear custom-property values on one repo. Per-repo by design so dry-run diffs, idempotency, and per-repo error isolation all work unchanged. The host may coalesce same-value writes onto the org batch endpoint (`PATCH /orgs/{org}/properties/values`, up to 30 repos/call) as an invisible optimisation.
- **Indexed search (strategy #3) is *not* the query backbone.** It may later be offered as an optional pre-filter feeding the same authoritative verify step, exactly as `searchCode` feeds `getContent`. The "narrow, then verify authoritatively" rule from the existing architecture applies; for properties, the bulk endpoint makes the narrow step unnecessary in the common case.
- **Values-only, org-only in v1.** The property (`ProjectType`) must already be defined in org settings. The app sets values; it does not create or edit property *definitions*. Custom properties do not exist on personal-account repos — out of scope.
- **Permissions are probed, not assumed.** The required fine-grained-token permissions are split by operation, and none is the classic `repo` scope the app currently assumes (verified against GitHub's permissions reference, 2026-06-17): the org bulk query (`GET /orgs/{org}/properties/values`) and the schema (`GET /orgs/{org}/properties/schema`) need **Organization → Custom properties: read**; setting values (`PATCH /repos/{owner}/{repo}/properties/values`) needs **Repository → Custom properties: write**; reading one repo's values needs only **Repository → Metadata: read** (mandatory on every fine-grained token anyway). The token must also have the **organization as its resource owner** — custom properties are org-only, so the permission is absent on a personal-account token, and classic PATs have no "Custom properties" permission at all. The host surfaces a 403 on any of these as one clear precondition error naming the missing permission, rather than opaque per-repo 403s at repo 137 of 200.
- **Allowed-values are enforced before the write — at arm time.** For single/multi-select properties, a value outside the org-defined allowed set is rejected by GitHub. The **armed** run validates each value against the org schema (`listPropertyDefs()`) and halts the repo before writing. The **dry run stays a pure preview that makes no host-initiated GitHub calls** — only the script's own reads are live (as with every recipe), and the recorded plan is local. Dry-run *also* validates allowed-values when the script has already fetched the schema (the host caches it), giving review-time feedback without the host issuing a hidden read; otherwise the mismatch surfaces as an arm-time halt with the same clear message.

## Options considered

### Read backbone — A: indexed `props.` search · B: authoritative org bulk read (chosen) · C: per-repo authoritative

- **A (indexed search):** fast, server-side filtered, minimal pagination. Rejected as the *backbone* because custom-property search is eventually consistent — the exact failure mode already documented for code search and the PR head filter. A query campaign that silently misses freshly-tagged repos repeats a bug the project has already paid to learn. Retained as an *optional* pre-filter that must be verified authoritatively.
- **B (org bulk values):** authoritative *and* cheap — a few paginated calls return real values for the whole org, filtered in JS. No staleness, one logical capability, and it makes write campaigns idempotent for free (current values are known, so repos already at target are skipped). Chosen as the backbone.
- **C (per-repo):** authoritative but N calls as a primary search. Kept as the *verify* / single-repo binding, not the query path.

### Scope — values-only (chosen) vs. schema management

- **Values-only:** the app sets values on properties an org admin has already defined. Lower privilege, smaller surface, covers the motivating use case. Chosen.
- **Schema management** (create/edit property definitions via `PUT /orgs/{org}/properties/schema/{name}`): more powerful, needs org-owner privilege, rarely needed, and easy to add later behind the same review/arm flow. Deferred.

### Primitive — custom properties (chosen) vs. topics

Custom properties model name/value; topics are flat tags. The request is name/value, so properties win. Topics are a cheaper-permission, any-repo surface worth adding separately if flat tagging is ever wanted (Revisit triggers).

## Rationale

This change adds a capability *surface* (repo metadata) without adding an execution *model* — the whole point of ADR 0001/0002. Query slots into the check phase beside `searchCode`/`getContent`; set slots into the update phase beside `putContent`, inheriting dry-run recording, before/after diffs, per-repo error isolation, the arm flow, the artifact/idempotency machinery, and the audit trail with zero new lifecycle code. The metadata "diff" (`old → new` value per repo) is in fact cleaner to review than a file diff.

Choosing the authoritative bulk read over indexed search is the same judgement the project already made elsewhere, applied before the bug rather than after it: GitHub's indexed filters lie about freshness, and this architecture is built on verifying authoritatively. Mapping permission 403s to a clear message, and enforcing allowed-values at arm time (with optional review-time feedback when the script has read the schema), keep the failure surface where the trust model wants it — enforced by the host before any write, never a surprise mid-write — while the dry run stays a faithful no-write, no-hidden-call preview.

## Consequences

**Positive**

- One new read capability (`listOrgProperties`/`getProperties`/`listPropertyDefs`) and one new write capability (`setProperties`) cover both halves of the requested feature.
- Query campaigns are authoritative by construction — immune to the staleness class that bit code/PR search.
- Write campaigns are idempotent and self-verifying: the same read capability that finds `ProjectType = rails` confirms a `set` campaign landed.
- Allowed-values and permission failures surface as a clear per-repo halt before any write (and at dry-run review when the script has read the schema), not as opaque runtime 403/422s.

**Negative / accepted trade-offs**

- A new token-permission requirement (org Custom properties, split read/write) beyond the current `repo` assumption; the app must detect and explain it.
- `RepoRef` / the host client grow a metadata surface they did not have; property *definitions* must be fetched to validate writes.
- Values-only means an org admin must pre-define the property; the app cannot bootstrap `ProjectType` itself in v1.

**Neutral**

- Indexed `props.` search and topics both remain available as later additions composing with this decision rather than competing with it.

## Revisit triggers

- **Org size makes the bulk read slow** → add the indexed `props.` pre-filter (strategy #3) feeding the authoritative verify step, as `searchCode` feeds `getContent`. Never let it become the sole source of truth.
- **Flat tagging is wanted** → add a topics capability (`getTopics`/`setTopics`); cheaper permission, works on any repo, separate API surface.
- **Bootstrapping properties is wanted** → add schema management (create/edit definitions) behind the same review/arm flow; requires org-owner privilege.
- **Personal-account repos need metadata** → custom properties cannot serve them; only topics can. Reopen the primitive choice for that context.
