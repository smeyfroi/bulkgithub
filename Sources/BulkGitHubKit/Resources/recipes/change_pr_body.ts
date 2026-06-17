const meta = {
  title: "Change PR body",
  phase: "merge" as const,
  apiVersion: 1,
  params: {
    body: "Updated by BulkGitHub.",
  },
};

/**
 * Replaces the description (body) of every pull request THIS job created with
 * the text in the `body` param. Registry-scoped by the host — only the job's
 * own PRs can be touched, nothing else in the organisation. The PR title and
 * the code on the branch are left unchanged.
 *
 * Dry-run records one editPR per PR; an armed re-run applies them.
 */
async function main(): Promise<void> {
  const { body } = job.params;
  const prs = await gh.listJobPRs();
  job.progress(`${prs.length} PR(s) in the job registry`);

  for (const pr of prs) {
    try {
      await gh.editPR(pr.repo, pr.number, body);
      job.log(`${pr.repo}: replaced body of #${pr.number}`);
    } catch (e) {
      job.error(pr.repo, String(e));
    }
  }
  job.progress("Done.");
}
