/**
 * BulkGitHub host API — v1, check-phase surface.
 *
 * This file is the contract between generated scripts, the in-app
 * type-checker, and the LLM prompt. Scripts run inside the app's
 * JavaScriptCore context; the globals declared here are the script's entire
 * world. There is no filesystem, no network, no process, no timers, no
 * fetch — and no credentials (the host signs all GitHub requests).
 *
 * The write surface (createBranch, putContent, createPR, mergePR, closePR,
 * deleteBranch) arrives with the update/merge phases and will ship as a
 * separate phase-specific declaration so that check scripts cannot even
 * type-check a write.
 */

interface Repo {
  /** "owner/name", e.g. "example-org/api-service" */
  readonly fullName: string;
  readonly name: string;
  readonly defaultBranch: string;
  readonly archived: boolean;
  readonly private: boolean;
}

interface PR {
  readonly repo: string;
  readonly number: number;
  readonly headRef: string;
  readonly headSha: string;
  readonly state: "open" | "closed" | "merged";
  readonly url: string;
}

interface Evidence {
  /** Path of the file the evidence came from (must have been fetched). */
  path: string;
  /** The fetched content (or relevant portion) backing the match. */
  excerpt: string;
  /** Human-readable explanation shown in the results table. */
  explanation?: string;
}

interface GitHub {
  /** All repositories in the configured organisation (host-paginated). */
  listOrgRepos(): Promise<Repo[]>;

  /**
   * One repository's metadata — the AUTHORITATIVE source for defaultBranch.
   * The organisation mixes "master" and "main" default branches, so never
   * hardcode a branch name. Repos from listOrgRepos carry the real default
   * branch; repos from searchCode (and bare names carried in job state) may
   * not — resolve them with getRepo before branching. Rejects when the
   * repository does not exist.
   */
  getRepo(repo: Repo | string): Promise<Repo>;

  /**
   * GitHub code search, automatically scoped to the configured organisation.
   * Results are CANDIDATE EVIDENCE ONLY — always fetch and verify content
   * before reporting a match. Search indexes are stale and snippet matches
   * are not proof. The defaultBranch on search results is NOT reliable —
   * use gh.getRepo when you need it.
   *
   * INCOMPLETE INDEX — do not use this to discover files at a KNOWN path.
   * Code search covers only the default branch, skips large files, and its
   * `path:` qualifier frequently returns zero for a file that exists. When
   * you know the path, enumerate instead: gh.listOrgRepos + gh.getContent,
   * or gh.listFiles with a glob. Reserve searchCode for genuinely unknown
   * locations, and treat empty results as "missed", not "absent".
   */
  searchCode(query: string): Promise<Repo[]>;

  /**
   * Fetch a file's content at a path (optionally at a ref). Resolves to null
   * when the file does not exist — handle that case with job.skip.
   */
  getContent(repo: Repo | string, path: string, ref?: string): Promise<string | null>;

  /**
   * File paths in the repository tree at ref (default branch HEAD when ref is
   * omitted), optionally filtered by a glob: `*` matches within one path
   * segment, `**` spans path segments (prefix a pattern with two asterisks
   * and a slash to match at any depth), plus `?` and `[abc]`. The listing
   * costs one API call — use it to find files, then gh.getContent to fetch
   * the ones that matter. Very large repositories may be truncated by the
   * GitHub tree API.
   */
  listFiles(repo: Repo | string, glob?: string, ref?: string): Promise<string[]>;

  /**
   * Resolve a ref to its SHA, or null if absent. Build the ref from the
   * repo's real default branch ("heads/" + repo.defaultBranch) — default
   * branches vary across the organisation, so "heads/main" hardcoded will
   * miss master-default repositories.
   */
  getRef(repo: Repo | string, ref: string): Promise<{ sha: string } | null>;

  /** Pull requests on a repository. */
  listPRs(
    repo: Repo | string,
    opts?: { head?: string; state?: "open" | "closed" | "all" }
  ): Promise<PR[]>;

  /** PR search, automatically scoped to the configured organisation. */
  searchPRs(query: string): Promise<PR[]>;
}

interface Job {
  /**
   * Mark a repository as a verified match. The host enforces that the
   * evidence path was actually fetched via gh.getContent in this run;
   * reporting unfetched "evidence" throws.
   */
  reportMatch(repo: Repo | string, evidence: Evidence): void;

  /** Mark a repository as skipped, with a clear human-readable reason. */
  skip(repo: Repo | string, reason: string): void;

  /** Record a per-repository failure. Wrap per-repo work in try/catch. */
  error(repo: Repo | string, message: string): void;

  /** Milestone progress shown live in the console. */
  progress(message: string): void;

  /** Free-form log line. */
  log(message: string): void;

  /** Read a value stored by an earlier phase of this job. */
  readState(key: string): unknown;

  /** Store a value for later phases of this job. */
  writeState(key: string, value: unknown): void;

  /** Resolved parameters: meta.params defaults merged with user edits. */
  readonly params: Record<string, string>;
}

interface ParseTools {
  /** Parse YAML to plain objects/arrays/scalars. Throws on invalid input. */
  yaml(text: string): unknown;
  /** Parse JSON. Throws on invalid input. */
  json(text: string): unknown;
  /** Parse TOML. (Not yet supported by the host — throws.) */
  toml(text: string): unknown;
}

interface ScriptMeta {
  title: string;
  phase: "check" | "update" | "merge";
  params?: Record<string, string>;
  apiVersion?: number;
}

declare const gh: GitHub;
declare const job: Job;
declare const parse: ParseTools;
declare const console: { log(...args: unknown[]): void };
