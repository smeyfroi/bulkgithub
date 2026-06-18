# Repository Custom Properties — Implementation Plan (v1)

> Extends [native-macos-bulkgithub-app-plan-v2.md](native-macos-bulkgithub-app-plan-v2.md). Design decisions and the options behind them are in [ADR 0003](../decisions/0003-repository-custom-properties-as-a-host-capability.md). This plan covers only the v1 scope agreed there: **query org repos by custom property (authoritative bulk read) and set custom-property values (values-only), org repos only, with dry-run + diff.**

> **Status (2026-06-17):** Implemented on branch `repo-custom-properties`, fixture-backed and fully tested (`swift test` green). All seven tasks below are done. Per the v2 "don't start live GitHub integration until confirmed" rule, this has **not** been exercised against the live API — the one real-world gate remaining is a **fine-grained token whose resource owner is the organisation**, with: **Organization → Custom properties: read** (query), **Repository → Custom properties: write** (set values), and **Repository → Metadata: read** (per-repo read; mandatory anyway). Classic PATs have no Custom-properties permission. The host surfaces a 403 there as a single legible message rather than opaque per-repo failures.

## Goal

Add repository **custom properties** as a host capability so campaigns can both:

- **Query (check phase):** "find repos where custom property `ProjectType` is `rails`."
- **Set (update phase):** "for all repos with a `project.json`, set `ProjectType` to the value of its `type` key."

No new execution model — query slots beside `searchCode`/`getContent`, set slots beside `putContent`, under the existing dry-run → review → arm → audit pipeline.

## Out of scope for v1

- Creating or editing property **definitions** (schema). The org admin pre-defines `ProjectType`; the app only sets values.
- **Topics** (flat tags) — separate API surface, deferred.
- **Personal-account** repos — custom properties are org-only.
- Indexed `props.` search as the query backbone — authoritative bulk read instead (the `props.` pre-filter is a documented later optimisation, not v1).

## Host API additions

Read bindings (present on every handle, including check):

```ts
// A custom-property value is a string, a list (multi-select), or null (unset).
type PropertyValue = string | string[] | null;

interface PropertyDef {
  name: string;
  valueType: "string" | "single_select" | "multi_select" | "true_false";
  allowedValues: string[] | null;   // null for free-text / true_false
}

interface GitHub {
  // ...existing read methods...

  // Authoritative bulk read — the query backbone. Real stored values, not indexed.
  listOrgProperties(): Promise<{ repo: Repo; properties: Record<string, PropertyValue> }[]>;

  // Authoritative per-repo read — sibling of getContent; verify / diff / idempotency.
  getProperties(repo: Repo | string): Promise<Record<string, PropertyValue>>;

  // Org property schema — lets a script validate a value before writing it.
  listPropertyDefs(): Promise<PropertyDef[]>;
}
```

Write binding (absent on read-only handles; recorded on dry-run; guarded on live):

```ts
interface GitHub {
  // Set/clear custom-property values on one repo. Per-repo by design so dry-run
  // diffs, idempotency, and per-repo error isolation all work unchanged.
  // Pass null as a value to clear it.
  setProperties(repo: Repo | string, values: Record<string, PropertyValue>): Promise<void>;
}
```

Notes:

- Keep the script-facing API **per-repo**. The host may coalesce identical values onto the org batch endpoint (`PATCH /orgs/{org}/properties/values`, ≤30 repos/call) as an invisible optimisation; the script and the plan stay per-repo.
- `setProperties` takes a map (the underlying API sets multiple at once). A single-property convenience wrapper can be added if recipes want it, but the map is the primitive.

## GitHub client (LiveGitHubClient) additions

| Capability | REST endpoint | Notes |
|---|---|---|
| `listOrgProperties` | `GET /orgs/{org}/properties/values` | Paginated (Link header). Authoritative values for every repo. |
| `getProperties` | `GET /repos/{owner}/{repo}/properties/values` | Returns set/defaulted values for one repo. |
| `listPropertyDefs` | `GET /orgs/{org}/properties/schema` | Property definitions: type + allowed values. |
| `setProperties` | `PATCH /repos/{owner}/{repo}/properties/values` | Body: `{ properties: [{ property_name, value }] }`; `value: null` clears. |
| (optional) batch | `PATCH /orgs/{org}/properties/values` | Host-side optimisation for same-value fan-out; ≤30 repos/call. |

Follows existing client conventions: `Bearer` token from `TokenProvider`, `X-GitHub-Api-Version: 2022-11-28`, pagination + rate-limit handling, `allow404` where a resource may be absent.

## Capability modes & guardrails

- **Check (read-only) handle:** read methods only. `setProperties` does not exist on the object — a check script cannot mutate metadata regardless of what the LLM wrote.
- **Recording handle (update dry-run):** **pure recording — the host makes no GitHub calls of its own.** `setProperties` records a planned per-repo action; the `before` side of the diff comes from the values the script already fetched via `getProperties` (a script read, live like every dry-run read), rendered `name: old → new`. Idempotency is the script's job (skip a repo already at target). Nothing here reaches GitHub.
- **Guarded live handle (update write):** writes execute only for repos selected in the results table; the destructive-class confirmation setting applies as for other writes.

Cross-cutting:

- **Permission errors made legible:** the required fine-grained-token permissions are split by operation — **Organization → Custom properties: read** for the query/schema reads, **Repository → Custom properties: write** for setting values, **Repository → Metadata: read** for a per-repo value read (and the token's resource owner must be the org). The host maps a 403 on any property endpoint to one clear message naming the missing permission, instead of opaque 403s mid-run.
- **Allowed-values validation (arm-time, with optional review-time feedback):** the **armed** run validates each value against the org schema (`listPropertyDefs()`, fetched on the write path) and halts the repo before writing if a single/multi-select value is outside `allowedValues` (GitHub would otherwise 422 it). The **dry run** validates too — but only against a schema the script has already fetched (the host caches `listPropertyDefs` results), so the dry run never issues a hidden read. Free-text and true/false skip the allowed-set check.
- **Property-exists check:** a write to a property name not in the schema is refused with "property not defined in org" (v1 is values-only) — at arm time, and at dry-run when the schema is cached.

## Validation / type-check

- Extend `bulkgh.d.ts` (read methods, available to check) and `bulkgh.update.d.ts` (`setProperties`) so generated/edited scripts are type-checked against the new surface, same pipeline as today.
- `PropertyValue` / `PropertyDef` types added to both declaration files.

## Native UX

- **Query results:** matched repos stream into the existing results table; the matched property name/value reads naturally as the match evidence (analogous to file-match evidence). No new pane needed.
- **Set dry-run:** the execution plan shows a per-repo metadata diff (`ProjectType: (unset) → rails`), reusing the before/after diff surface. No-op repos render as skipped; an allowed-values mismatch renders as a plan error when the schema is cached, otherwise it surfaces as an arm-time halt.
- **Precondition error:** if the permission probe fails, surface it as a single banner/alert before any per-repo work, with the missing permission named.

## Example recipes (to ship with the feature)

- `find_repos_by_property.ts` (check): read `listOrgProperties()`, filter `properties.ProjectType === "rails"`, `reportMatch` each.
- `set_property_from_json.ts` (update): reads the org schema once (`listPropertyDefs`, a plain read) to confirm the property exists and to validate values; then per repo `getContent("project.json")` → `parse.json` → read `type` → check against `allowedValues` → `getProperties` (idempotency + accurate diff) → `setProperties`; `skip` on absent file / missing key / disallowed value / already-at-target. The host re-enforces allowed-values at arm time as a backstop.

## Task breakdown

1. **Client:** add the four (+optional batch) endpoints to `GitHubClient` protocol + `LiveGitHubClient`; model `PropertyValue`/`PropertyDef`; pagination on the org list. Unit-test against fixtures (mirror existing client tests).
2. **Bindings:** expose read methods on all handles and `setProperties` on update handles in `HostBindings`; record planned actions + diffs in `JobCollector`; idempotency no-op detection.
3. **Guardrails:** clear 403 mapping for missing permissions; allowed-values + property-exists enforced at arm time (dry run stays a pure preview — no host-initiated GitHub calls); per-repo error isolation.
4. **Contracts:** extend `bulkgh.d.ts` / `bulkgh.update.d.ts`; regen any bundled type-check fixtures.
5. **Recipes + system prompt:** add the two recipes; document the read-authoritative-not-indexed rule and the org-only / values-only constraints in the prompt.
6. **UX:** property-value evidence in results; metadata diff in the dry-run plan; precondition banner.
7. **Docs:** note the new token permission requirement wherever token scope is documented — a fine-grained token owned by the org with Organization → Custom properties (read), Repository → Custom properties (write), Repository → Metadata (read).

## Open questions / confirm before build

- **Token:** the token must be a **fine-grained PAT whose resource owner is the organisation** (a classic PAT has no Custom-properties permission, and a personal-account fine-grained token never shows it) carrying Organization → Custom properties (read), Repository → Custom properties (write), Repository → Metadata (read). This gates live use — confirm before pointing the app at the live API, consistent with the v2 "don't start live integration until confirmed" rule.
- **Org list size:** confirm the org's repo count makes a full `listOrgProperties` scan comfortable (it should; revisit triggers in ADR 0003 cover the indexed pre-filter if not).
- **Single-property convenience wrapper:** ship `setProperties(map)` only, or also a `setProperty(repo, name, value)` sugar? (Map is the primitive; sugar is cheap to add.)
