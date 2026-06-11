const meta: ScriptMeta = {
  title: "Find repos where files under a path contain a string",
  phase: "check",
  apiVersion: 1,
  params: {
    glob: "deploy/**",
    needle: "ec2-shell-prod-eu-west-1-keypair-1",
  },
};

async function main(): Promise<void> {
  const { glob, needle } = job.params;

  const repos = await gh.listOrgRepos();
  job.progress(`scanning ${repos.length} repos for ${glob} files containing the string`);

  // Recorded for the update phase via job state — the update script reuses
  // these matches instead of re-searching the organisation.
  const matches: { repo: string; defaultBranch: string; paths: string[] }[] = [];

  for (const repo of repos) {
    if (repo.archived) {
      job.skip(repo, "archived");
      continue;
    }
    try {
      const files = await gh.listFiles(repo, glob);
      if (files.length === 0) {
        job.skip(repo, `no files matching ${glob}`);
        continue;
      }
      const hits: string[] = [];
      for (const path of files) {
        const text = await gh.getContent(repo, path);
        if (text === null || !text.includes(needle)) continue;
        const lines = text.split("\n");
        const index = lines.findIndex(line => line.includes(needle));
        const excerpt = lines.slice(Math.max(0, index - 2), index + 3).join("\n");
        job.reportMatch(repo, {
          path,
          excerpt,
          explanation: lines[index].trim(),
        });
        hits.push(path);
      }
      if (hits.length === 0) {
        job.skip(repo, `string not found in ${files.length} file(s) matching ${glob}`);
      } else {
        matches.push({ repo: repo.fullName, defaultBranch: repo.defaultBranch, paths: hits });
      }
    } catch (e) {
      job.error(repo, String(e));
    }
  }

  job.writeState("stringMatches", matches);
  job.progress(`scan complete — ${matches.length} repo(s) recorded for the update phase`);
}
