/**
 * BulkGitHub host API — update-phase surface. Loaded ALONGSIDE bulkgh.d.ts;
 * TypeScript declaration merging adds these methods to the GitHub interface.
 * Check-phase scripts are validated WITHOUT this file, so a check script that
 * tries to write fails the type-check before it can run.
 *
 * Phase 3 semantics: dry run. Every write below is RECORDED into an execution
 * plan that the user reviews as native diffs — nothing reaches GitHub, and
 * the host returns synthesized (clearly fake) responses so read-modify-write
 * logic still flows. A later phase re-runs the same script against a guarded
 * live handle for the repositories the user selects.
 *
 * House rules for update scripts:
 * - Branch names MUST start with "bulkgh/" — host-enforced; these are the
 *   only branches the app will ever create or delete.
 * - Fetch a file with gh.getContent before gh.putContent so the plan can
 *   show a before/after diff.
 * - To remove a file, use gh.deleteContent (also "bulkgh/"-only); fetch it
 *   first so the plan can show what is being deleted.
 * - One branch per repo, then one putContent/deleteContent per changed file,
 *   then a single createPR.
 */

interface GitHub {
  /**
   * Create a branch at fromSha (get it via gh.getRef on the default branch).
   * Dry run: recorded; resolves to a synthetic sha.
   */
  createBranch(repo: Repo | string, name: string, fromSha: string): Promise<{ sha: string }>;

  /**
   * Create or update one file on a "bulkgh/"-prefixed branch.
   * Dry run: recorded with a before/after diff for review.
   */
  putContent(
    repo: Repo | string,
    path: string,
    content: string,
    opts: { branch: string; message: string; expectedSha?: string }
  ): Promise<void>;

  /**
   * Delete one file from a "bulkgh/"-prefixed branch.
   * Fetch it with gh.getContent first so the dry run can show what is being
   * removed. Deleting a file that is already absent is a no-op.
   * Dry run: recorded with the deletion shown as a diff for review.
   */
  deleteContent(
    repo: Repo | string,
    path: string,
    opts: { branch: string; message: string }
  ): Promise<void>;

  /**
   * Open a pull request from a "bulkgh/"-prefixed head branch.
   * Dry run: recorded; resolves to a synthetic PR (number 0).
   */
  createPR(
    repo: Repo | string,
    opts: { head: string; title: string; body: string }
  ): Promise<PR>;

  /**
   * Set (or clear) repository custom-property VALUES. The property must already
   * be defined at the org level — this sets values only, it does not create the
   * definition. A null value clears a property. Single/multi-select values must
   * be in the property's allowed set (validated at dry run).
   *
   * Unlike file edits there is NO branch or PR — this is a direct, terminal
   * repo-metadata write that takes effect the moment it is armed.
   *
   * Fetch current values with gh.getProperties FIRST: it lets you skip repos
   * already at the target (idempotency), gives the dry-run plan an accurate
   * before→after diff, and makes the armed run's drift guard correct.
   *
   * Dry run: recorded as a planned action with the per-key diff.
   */
  setProperties(
    repo: Repo | string,
    values: Record<string, PropertyValue>
  ): Promise<void>;
}
