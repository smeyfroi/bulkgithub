const meta = {
  title: "Cancel job: close PRs, delete branches",
  phase: "merge" as const,
  apiVersion: 1,
  params: {},
};

/**
 * Winds the job back: closes its open pull requests without merging and
 * deletes its branches. Registry-scoped by the host — only PRs and branches
 * THIS job created can be touched, nothing else in the organisation.
 */
async function main(): Promise<void> {
  const prs = await gh.listJobPRs();
  job.progress(`cancelling ${prs.length} registry PR(s)`);

  for (const pr of prs) {
    try {
      if (pr.state === "open") {
        await gh.closePR(pr.repo, pr.number);
      }
      await gh.deleteBranch(pr.repo, pr.headRef);
      job.log(`${pr.repo}: closed #${pr.number}, deleted ${pr.headRef}`);
    } catch (e) {
      job.error(pr.repo, String(e));
    }
  }
  job.progress("Done.");
}
