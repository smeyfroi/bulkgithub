const meta: ScriptMeta = {
  title: "Cancel job",
  phase: "merge",
  apiVersion: 1,
  prompt: "cancel this job: close its open pull requests without merging and delete its branches",
  icon: "xmark.circle",
  params: {},
};

/**
 * Winds the job back: closes its open pull requests without merging and
 * deletes its branches — including orphan branches that were never PR'd.
 * Registry-scoped by the host — only PRs and branches THIS job created can be
 * touched, nothing else in the organisation.
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

  // Orphan branches: created by this job but never PR'd (e.g. createPR failed),
  // so listJobPRs can't see them. Delete them too — otherwise they sit in the
  // registry forever and block starting a new job.
  const branches = await gh.listJobBranches();
  const orphans = branches.filter(
    (b) => !prs.some((pr) => pr.repo === b.repo && pr.headRef === b.name)
  );
  if (orphans.length > 0) {
    job.progress(`deleting ${orphans.length} orphan branch(es)`);
  }
  for (const b of orphans) {
    try {
      await gh.deleteBranch(b.repo, b.name);
      job.log(`${b.repo}: deleted orphan branch ${b.name}`);
    } catch (e) {
      job.error(b.repo, String(e));
    }
  }
  job.progress("Done.");
}
