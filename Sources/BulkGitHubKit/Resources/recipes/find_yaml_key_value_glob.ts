const meta: ScriptMeta = {
  title: "Find repos where a YAML file under a glob sets a key to a value",
  phase: "check",
  apiVersion: 1,
  params: {
    glob: "deploy/**",
    extensions: "yml,yaml,template",
    key: "RetentionInDays",
    value: "14",
  },
};

/**
 * Recursively collects every occurrence of `key` in the parsed document,
 * with the dotted path it was found at. Real-world YAML buries keys deep
 * (CloudFormation: Resources.X.Properties.RetentionInDays) — a top-level
 * lookup misses almost everything.
 */
function findKey(node: unknown, key: string, path: string,
                 hits: { path: string; value: unknown }[]): void {
  if (Array.isArray(node)) {
    node.forEach((item, index) => findKey(item, key, `${path}[${index}]`, hits));
    return;
  }
  if (node === null || typeof node !== "object") return;
  for (const [name, value] of Object.entries(node as Record<string, unknown>)) {
    const here = path === "" ? name : `${path}.${name}`;
    if (name === key) hits.push({ path: here, value });
    findKey(value, key, here, hits);
  }
}

async function main(): Promise<void> {
  const { glob, extensions, key, value } = job.params;
  const suffixes = extensions.split(",").map(e => "." + e.trim());

  // Only the file's SHAPE is known, not its path — and code search cannot
  // express "key: value somewhere under a glob". Enumerate the organisation
  // and inspect each repo's YAML-ish files directly. CloudFormation tags
  // (!Ref, !GetAtt, …) parse as plain values, so .template files work.
  const repos = await gh.listOrgRepos();
  job.progress(`scanning ${repos.length} repo(s) for ${key} = ${value} under ${glob} (${extensions})`);

  for (const repo of repos) {
    if (repo.archived) {
      job.skip(repo, "archived");
      continue;
    }
    try {
      const files = await gh.listFiles(repo, glob);
      const yamlFiles = files.filter(path => suffixes.some(s => path.endsWith(s)));
      if (yamlFiles.length === 0) {
        job.skip(repo, `no ${extensions} files matching ${glob}`);
        continue;
      }
      let matched = false;
      const seen: string[] = [];
      for (const path of yamlFiles) {
        const text = await gh.getContent(repo, path);
        if (text === null) continue;
        let doc: unknown;
        try {
          doc = parse.yaml(text);
        } catch {
          continue; // unreadable YAML is not evidence
        }
        const hits: { path: string; value: unknown }[] = [];
        findKey(doc, key, "", hits);
        const match = hits.find(hit => String(hit.value) === value);
        if (match !== undefined) {
          job.reportMatch(repo, {
            path,
            excerpt: text,
            explanation: `${match.path} = ${String(match.value)} in ${path}`,
          });
          matched = true;
          break;
        }
        for (const hit of hits.slice(0, 2)) {
          seen.push(`${path}: ${hit.path} = ${String(hit.value)}`);
        }
      }
      if (!matched) {
        job.skip(repo, seen.length > 0
          ? `${key} differs (${seen.join("; ")})`
          : `${key} not found in ${yamlFiles.length} file(s)`);
      }
    } catch (e) {
      job.error(repo, String(e));
    }
  }

  job.progress("scan complete");
}
