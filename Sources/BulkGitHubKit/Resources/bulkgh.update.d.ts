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
 * - One branch per repo, then one putContent per changed file, then a single
 *   createPR.
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
   * Open a pull request from a "bulkgh/"-prefixed head branch.
   * Dry run: recorded; resolves to a synthetic PR (number 0).
   */
  createPR(
    repo: Repo | string,
    opts: { head: string; title: string; body: string }
  ): Promise<PR>;
}
