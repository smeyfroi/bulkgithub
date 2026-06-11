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
      let matched = false;
      for (const path of files) {
        const text = await gh.getContent(repo, path);
        if (text === null) continue;
        if (!text.includes(needle)) continue;
        const lines = text.split("\n");
        const index = lines.findIndex(line => line.includes(needle));
        const excerpt = lines.slice(Math.max(0, index - 2), index + 3).join("\n");
        job.reportMatch(repo, {
          path,
          excerpt,
          explanation: lines[index].trim(),
        });
        matched = true;
      }
      if (!matched) {
        job.skip(repo, `string not found in ${files.length} file(s) matching ${glob}`);
      }
    } catch (e) {
      job.error(repo, String(e));
    }
  }

  job.progress("scan complete");
}
