const meta: ScriptMeta = {
  title: "Find YAML key/value",
  phase: "check",
  apiVersion: 1,
  prompt: "find repos that contain \"project.json\" where the \"type\" value is \"rails\"",
  icon: "doc.text.magnifyingglass",
  params: {
    path: "project.json",
    key: "type",
    value: "rails",
  },
};

async function main(): Promise<void> {
  const { path, key, value } = job.params;

  const candidates = await gh.searchCode(`path:${path} "${value}"`);
  job.progress(`${candidates.length} candidate repo(s) from code search`);

  const active = candidates.filter(repo => !repo.archived);
  for (const repo of candidates) if (repo.archived) job.skip(repo, "archived");

  // Verify every candidate in ONE batched read rather than a GET each. A repo
  // whose file the index pointed at is gone (stale hit) comes back null and is
  // skipped; a batch can't flag a single repo as failed, so an unreadable one
  // reads as absent.
  const texts = await gh.getContentBatch(active.map(repo => ({ repo, path })));

  active.forEach((repo, i) => {
    const text = texts[i];
    if (text === null) {
      job.skip(repo, "file absent");
      return;
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
  });

  job.progress("verification complete");
}
