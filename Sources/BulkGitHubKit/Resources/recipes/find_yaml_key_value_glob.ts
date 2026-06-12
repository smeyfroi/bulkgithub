const meta: ScriptMeta = {
  title: "Find repos where a YAML file under a glob sets a key to a value",
  phase: "check",
  apiVersion: 1,
  params: {
    glob: "deploy/**",
    key: "RetentionInDays",
    value: "14",
  },
};

async function main(): Promise<void> {
  const { glob, key, value } = job.params;

  // Only the file's SHAPE is known, not its path — and code search cannot
  // express "key: value somewhere under a glob". Enumerate the organisation
  // and inspect each repo's YAML files directly.
  const repos = await gh.listOrgRepos();
  job.progress(`scanning ${repos.length} repo(s) for YAML under ${glob} where ${key} = ${value}`);

  for (const repo of repos) {
    if (repo.archived) {
      job.skip(repo, "archived");
      continue;
    }
    try {
      const files = await gh.listFiles(repo, glob);
      const yamlFiles = files.filter(path => /\.ya?ml$/.test(path));
      if (yamlFiles.length === 0) {
        job.skip(repo, `no YAML files matching ${glob}`);
        continue;
      }
      let matched = false;
      const seen: string[] = [];
      for (const path of yamlFiles) {
        const text = await gh.getContent(repo, path);
        if (text === null) continue;
        let doc: Record<string, unknown> | null;
        try {
          doc = parse.yaml(text) as Record<string, unknown> | null;
        } catch {
          continue; // unreadable YAML is not evidence
        }
        const actual = doc ? doc[key] : undefined;
        if (actual === undefined) continue;
        if (String(actual) === value) {
          job.reportMatch(repo, {
            path,
            excerpt: text,
            explanation: `${key} = ${String(actual)} in ${path}`,
          });
          matched = true;
          break;
        }
        seen.push(`${path}: ${key} = ${String(actual)}`);
      }
      if (!matched) {
        job.skip(repo, seen.length > 0
          ? `${key} differs (${seen.join("; ")})`
          : `${key} not found in ${yamlFiles.length} YAML file(s)`);
      }
    } catch (e) {
      job.error(repo, String(e));
    }
  }

  job.progress("scan complete");
}
