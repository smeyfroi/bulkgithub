const meta: ScriptMeta = {
  title: "Merge approved PRs",
  phase: "merge",
  apiVersion: 1,
  prompt: "squash-merge the approved pull requests this job created, then delete their branches",
  icon: "arrow.triangle.merge",
  params: {},
};

/**
 * Merges the pull requests THIS job created, where the user has approved
 * them in the app. The host enforces every safety property: registry
 * scoping, the approval requirement, and that the head SHA still matches
 * what was approved. Branches are deleted only after their PR merges.
 */
async function main(): Promise<void> {
  const prs = await gh.listJobPRs();
  job.progress(`${prs.length} PR(s) in the job registry`);

  for (const pr of prs) {
    try {
      if (pr.state !== "open") {
        job.skip(pr.repo, `PR #${pr.number} is ${pr.state}`);
        continue;
      }
      await gh.mergePR(pr.repo, pr.number, { expectedHeadSha: pr.headSha });
      await gh.deleteBranch(pr.repo, pr.headRef);
      job.log(`${pr.repo}: merged #${pr.number}, deleted ${pr.headRef}`);
    } catch (e) {
      job.error(pr.repo, String(e));
    }
  }
  job.progress("Done.");
}
