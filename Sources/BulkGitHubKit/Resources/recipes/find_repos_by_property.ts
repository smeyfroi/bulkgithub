const meta: ScriptMeta = {
  title: "Find repos by custom property",
  phase: "check",
  apiVersion: 1,
  params: {
    property: "ProjectType",
    value: "rails",
  },
};

async function main(): Promise<void> {
  const { property, value } = job.params;

  // Authoritative bulk read — real stored values, NOT a search index, so there
  // is no staleness to defend against: filter in plain code.
  const all = await gh.listOrgProperties();
  job.progress(`scanning ${all.length} repo(s) for ${property} = ${value}`);

  for (const { repo, properties } of all) {
    const actual = properties[property];
    const display = Array.isArray(actual) ? actual.join(", ") : String(actual);
    const matches = Array.isArray(actual) ? actual.includes(value) : actual === value;
    if (matches) {
      job.reportMatch(repo, {
        path: `custom property: ${property}`,
        excerpt: `${property} = ${display}`,
        explanation: `${property} = ${value}`,
      });
    } else {
      job.skip(repo, actual === undefined || actual === null
        ? `${property} unset`
        : `${property} = ${display} (differs)`);
    }
  }

  job.progress("query complete");
}
