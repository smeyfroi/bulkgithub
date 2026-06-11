# ADR 0002: The Merge Phase Stays Script-Driven Despite Being Deterministic

- **Status:** Accepted
- **Date:** 2026-06-11
- **Decision owner:** Steve
- **Input:** Design discussion during phase 5 implementation (Claude, 2026-06-11), after the full check → update → apply → approve → merge loop was first rehearsed against fixtures

## Context

Phases 1–4 use LLM-generated TypeScript because the business logic genuinely
varies per campaign: what to search for, how to verify it, how to edit files.
The merge phase is different. Its canonical actions are fully deterministic:
list the job's PRs, squash-merge the approved ones whose head SHA still
matches the approval, delete the job branches — or, for cancel, close the PRs
and delete the branches. The two shipped recipes (`merge_approved_prs`,
`cancel_job`) take zero parameters, their prompts add nothing, and every
safety property (registry scoping, the approval gate, the head-SHA
precondition, squash-only, the `bulkgh/` prefix) is enforced by the host, not
the script. A native "Merge approved" button calling the same client methods
would behave identically.

So why route this step through the LLM/JSC machinery at all? This ADR records
the answer, because the question will recur every time someone reads the
merge recipes and notices they contain no decisions.

## Decision

**Merging and cancelling remain script phases, executed by the same engine,
capability handles, and dry-run → review → arm pipeline as updates. The LLM
is optional in practice — the canonical recipes are loaded by click, not
generated — but the execution model does not special-case determinism.**

Three reasons, in order of weight:

### 1. One execution model for every effect

The architecture's core bet (ADR 0001, plan v2) is that everything effectful
flows through one pipeline: script → type-check → review → dry-run plan →
arm → audit. Because merge is "just another script phase" it inherited, with
zero new code, the machinery phases 3–4 paid for: the dry-run/armed split,
plan-conformance cursors, the Apply arming flow, halt semantics, per-repo
error isolation, cancellation, the watchdog, and the audit trail. The
plan-conformance and drift machinery worked for merge actions unchanged on
first rehearsal. A native merge path would be a second implementation of the
same lifecycle (a dry-run preview, per-repo errors, a stop button are all
still wanted), and second implementations are where bugs live.

### 2. It forces the invariants into the host

The trust model is "scripts are untrusted; the host enforces the rules".
Because merge is script-driven, the merge invariants had to be implemented as
host guarantees rather than UI behaviour: even a malicious or hallucinated
script cannot merge an unapproved PR, touch a branch or PR outside the job's
artifact registry, or merge past a head that moved since approval. If merge
were a native button, those rules would exist only as app logic that nothing
adversarial ever exercises. The deterministic recipe acts as a permanent
proof that the cage is real — and the capability surface already exists,
soak-tested, for the day scripted automation near merges is actually wanted.

### 3. The variability arrives later, at the policy level

"Merge the approved PRs" is the degenerate case. Real campaigns grow merge
*policy*: merge in waves of five and stop on the first conflict; only repos
whose CI is green; skip anything labelled `hold`; close PRs that sat
unreviewed for two weeks. In this architecture those are prompt-level
variations on the recipe running under the same host guarantees — not native
feature requests with bespoke UI. The deterministic recipe is simply the
policy-free script.

## Options considered

### Option A — Native deterministic merge (no script)

A "Merge approved" button calling the GitHub client directly. Simplest UX;
identical behaviour for the canonical case. Rejected because it duplicates
the run lifecycle natively, moves the merge invariants out of the
host-vs-script trust boundary into unexercised app logic, and dead-ends the
moment merge policy varies.

### Option B — Script-driven merge, same pipeline as updates (chosen)

As described above. Cost: ceremony (load recipe → dry run → apply where one
button could do) and one more declaration surface (`bulkgh.merge.d.ts`) to
maintain.

### Option C — Hybrid: native shortcut over the script path

Keep the engine as the only executor, but add a native "Merge approved…"
button that loads the canonical recipe and starts the dry run in one click —
sugar, not a second execution model. Not rejected: this is the sanctioned
mitigation if Option B's ceremony grates. It must remain a shortcut into the
same pipeline, never a bypass.

## Consequences

- The merge recipes look trivially thin. That is the point: all correctness
  lives in the host bindings, and the recipes double as permanent fixtures
  exercising the registry/approval/SHA guards.
- Users click a recipe rather than a button; the LLM is not consulted unless
  a policy variation is asked for in the prompt.
- Any future "smart" merge behaviour starts from a prompt, not a feature
  branch.

## Revisit triggers

- The ceremony measurably discourages use of the merge phase → implement
  Option C (shortcut button into the same pipeline).
- A merge-policy need arises that the host surface cannot express safely
  (e.g. CI-status gating) → extend `bulkgh.merge.d.ts` via contract review,
  as with all capability additions.
- The host invariants and the recipe layer ever disagree about who enforces
  a rule → the host wins; recipes must stay correct with a hostile script
  assumed.
