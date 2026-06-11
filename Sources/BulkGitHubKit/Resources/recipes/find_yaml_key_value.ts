const meta: ScriptMeta = {
  title: "Find repos where a YAML file sets a key to a value",
  phase: "check",
  apiVersion: 1,
  params: {
    path: "deploy/prod.yml",
    key: "account_id",
    value: "481832923858",
  },
};

async function main(): Promise<void> {
  const { path, key, value } = job.params;

  const candidates = await gh.searchCode(`path:${path} "${value}"`);
  job.progress(`${candidates.length} candidate repo(s) from code search`);

  for (const repo of candidates) {
    if (repo.archived) {
      job.skip(repo, "archived");
      continue;
    }
    try {
      const text = await gh.getContent(repo, path);
      if (text === null) {
        job.skip(repo, "file absent");
        continue;
      }
      const doc = parse.yaml(text) as Record<string, unknown> | null;
      const actual = doc ? doc[key] : undefined;
      if (actual !== undefined && String(actual) === value) {
        job.reportMatch(repo, {
          path,
          excerpt: text,
          explanation: `${key} = ${String(actual)}`,
        });
      } else {
        job.skip(repo, actual === undefined ? `${key} missing` : `${key} = ${String(actual)} (differs)`);
      }
    } catch (e) {
      job.error(repo, String(e));
    }
  }

  job.progress("verification complete");
}
