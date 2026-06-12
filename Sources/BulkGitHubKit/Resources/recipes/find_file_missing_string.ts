const meta: ScriptMeta = {
  title: "Find repos whose file is missing a string",
  phase: "check",
  apiVersion: 1,
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

  const found: { repo: string; defaultBranch: string }[] = [];
  for (const repo of repos) {
    if (repo.archived) {
      job.skip(repo, "archived");
      continue;
    }
    try {
      const text = await gh.getContent(repo, path);
      if (text === null) {
        job.skip(repo, `${path} absent`);
        continue;
      }
      if (text.includes(marker)) {
        job.skip(repo, `already contains "${marker}"`);
        continue;
      }
      job.reportMatch(repo, {
        path,
        excerpt: text,
        explanation: `"${marker}" missing from ${path}`,
      });
      found.push({ repo: repo.fullName, defaultBranch: repo.defaultBranch });
    } catch (e) {
      job.error(repo, String(e));
    }
  }

  // Carry the matches so an update script can plan without repeating the scan.
  job.writeState("missingMarker", found);
  job.progress(`${found.length} repo(s) missing "${marker}"`);
}
