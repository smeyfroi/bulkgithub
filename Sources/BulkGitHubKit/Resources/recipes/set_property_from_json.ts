const meta: ScriptMeta = {
  title: "Set custom property from JSON value",
  phase: "update",
  apiVersion: 1,
  prompt: "for all repos that contain project.json, set the custom property \"ProjectType\" to the value of the \"type\" key in the project.json",
  icon: "tag",
  params: {
    file: "project.json",
    jsonKey: "type",
    property: "ProjectType",
  },
};

async function main(): Promise<void> {
  const { file, jsonKey, property } = job.params;

  // Read the org schema once (a plain read) so values can be validated up front
  // — the dry run then shows allowed-value problems at review time, and the
  // property is confirmed to exist before we plan anything.
  const defs = await gh.listPropertyDefs();
  const def = defs.find(d => d.name === property);
  if (!def) {
    job.log(`custom property "${property}" is not defined in the organisation — define it in org settings first (this recipe sets values only)`);
    return;
  }

  const repos = await gh.listOrgRepos();
  job.progress(`scanning ${repos.length} repo(s): ${file} → custom property ${property}`);

  for (const repo of repos) {
    if (repo.archived) {
      job.skip(repo, "archived");
      continue;
    }
    try {
      const text = await gh.getContent(repo, file);
      if (text === null) {
        job.skip(repo, `${file} absent`);
        continue;
      }
      const doc = parse.json(text) as Record<string, unknown> | null;
      const raw = doc ? doc[jsonKey] : undefined;
      if (raw === undefined || raw === null) {
        job.skip(repo, `${jsonKey} missing in ${file}`);
        continue;
      }
      const value = String(raw);

      // Single/multi-select properties only accept their allowed values; skip
      // (with a clear reason) rather than plan a write GitHub would reject.
      if (def.allowedValues && !def.allowedValues.includes(value)) {
        job.skip(repo, `${value} is not an allowed value for ${property} (allowed: ${def.allowedValues.join(", ")})`);
        continue;
      }

      // Read current values: skip repos already at target (idempotent), give the
      // plan an accurate before→after diff, and keep the armed drift guard correct.
      const current = await gh.getProperties(repo);
      if (current[property] === value) {
        job.skip(repo, `${property} already ${value}`);
        continue;
      }
      await gh.setProperties(repo, { [property]: value });
    } catch (e) {
      job.error(repo, String(e));
    }
  }

  job.progress("dry run complete — review the property changes per repo");
}
