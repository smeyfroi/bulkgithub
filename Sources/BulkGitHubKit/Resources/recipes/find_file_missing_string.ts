const meta: ScriptMeta = {
  title: "Find file missing a string",
  phase: "check",
  apiVersion: 1,
  prompt: "find repos where the file README.md does not contain \"# License\"",
  icon: "magnifyingglass.circle",
  params: {
    path: "README.md",
    marker: "# License",
  },
};

async function main(): Promise<void> {
  const { path, marker } = job.params;

  // Absence cannot be searched: code search only proves presence, and its
  // index is incomplete anyway. Enumerate the organisation and check each
  // repository's file directly.
  const repos = await gh.listOrgRepos();
  job.progress(`checking ${repos.length} repo(s) for ${path} missing "${marker}"`);

  const active = repos.filter(repo => !repo.archived);
  for (const repo of repos) if (repo.archived) job.skip(repo, "archived");

  // One batched read instead of a GET per repo: an org-wide scan collapses to
  // a handful of requests, drawn from a quota pool separate from the REST
  // budget. A repo whose file is missing (or unreadable) comes back as null and
  // is skipped — a batch has no per-repo try/catch, so it can't single one out
  // as failed the way a getContent loop can.
  const texts = await gh.getContentBatch(active.map(repo => ({ repo, path })));

  const found: { repo: string; defaultBranch: string }[] = [];
  active.forEach((repo, i) => {
    const text = texts[i];
    if (text === null) {
      job.skip(repo, `${path} absent`);
      return;
    }
    if (text.includes(marker)) {
      job.skip(repo, `already contains "${marker}"`);
      return;
    }
    job.reportMatch(repo, {
      path,
      excerpt: text,
      explanation: `"${marker}" missing from ${path}`,
    });
    found.push({ repo: repo.fullName, defaultBranch: repo.defaultBranch });
  });

  // Carry the matches so an update script can plan without repeating the scan.
  job.writeState("missingMarker", found);
  job.progress(`${found.length} repo(s) missing "${marker}"`);
}
