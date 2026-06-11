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
  /** "owner/name", e.g. "geome/api-service" */
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
   * GitHub code search, automatically scoped to the configured organisation.
   * Results are CANDIDATE EVIDENCE ONLY — always fetch and verify content
   * before reporting a match. Search indexes are stale and snippet matches
   * are not proof.
   */
  searchCode(query: string): Promise<Repo[]>;

  /**
   * Fetch a file's content at a path (optionally at a ref). Resolves to null
   * when the file does not exist — handle that case with job.skip.
   */
  getContent(repo: Repo | string, path: string, ref?: string): Promise<string | null>;

  /** Resolve a ref (e.g. "heads/main") to its SHA, or null if absent. */
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
