/**
 * BulkGitHub host API — merge-phase surface. Loaded ALONGSIDE bulkgh.d.ts;
 * TypeScript declaration merging adds these methods to the GitHub interface.
 * Check and update scripts are validated WITHOUT this file.
 *
 * The merge surface operates ONLY on this job's artifact registry: the
 * branches and pull requests that THIS job's armed runs created. The host
 * refuses anything else — a merge script cannot touch a PR or branch the
 * job does not hold a receipt for.
 *
 * Like updates, merge scripts dry-run by default: every call below is
 * recorded into a reviewable plan; an armed re-run executes it.
 *
 * House rules for merge scripts:
 * - Merging requires the user's in-app approval of that PR, and the head
 *   SHA must still match what was approved — an approval is for a specific
 *   state of the branch, not forever. Pass the headSha from gh.listJobPRs.
 * - Merges are squash merges. There is no other method.
 * - Delete a job branch only after its PR is merged or closed.
 */

interface GitHub {
  /**
   * The pull requests THIS job created (the artifact registry), each with
   * its current remote state — open/closed/merged and the current head SHA.
   */
  listJobPRs(): Promise<PR[]>;

  /**
   * Squash-merge one job PR. Requires user approval in the app, and
   * expectedHeadSha must match both the approved SHA and the current head.
   * Dry run: recorded; resolves to a synthetic merge sha.
   */
  mergePR(
    repo: Repo | string,
    number: number,
    opts: { expectedHeadSha: string }
  ): Promise<{ sha: string }>;

  /**
   * Close one job PR without merging (the cancel flow).
   * Dry run: recorded.
   */
  closePR(repo: Repo | string, number: number): Promise<void>;

  /**
   * Delete one job branch (must be "bulkgh/"-prefixed AND in the registry).
   * Dry run: recorded.
   */
  deleteBranch(repo: Repo | string, name: string): Promise<void>;
}
