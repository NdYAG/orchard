/**
 * orchard for pi: `/orchard new <name> | done | status | prune`.
 *
 * pi has no worktree hook. What it does have: a session file's header records its working directory,
 * and switching to a session in another directory rebuilds pi's cwd-bound runtime (tools, AGENTS.md,
 * shell) there. So "entering a worktree" is: claim a plot with the CLI, then move the session into it.
 */
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, join, sep } from "node:path";
import { fileURLToPath } from "node:url";

import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import type { AutocompleteItem } from "@earendil-works/pi-tui";

// The context handed to `withSession` after a switch; pi does not export its type by name.
type ReplacedSessionContext = Parameters<NonNullable<NonNullable<Parameters<ExtensionCommandContext["switchSession"]>[1]>["withSession"]>>[0];

const STATUS_KEY = "orchard";
const SUBCOMMANDS = ["new", "done", "status", "prune"];
const NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

interface Plot {
  id: string;
  state: string;
  path: string | null;
}

interface RepoStatus {
  configured: boolean;
  root: string;
  worktrees_dir: string;
  plots: Plot[];
}

interface Claimed {
  path: string;
  branch: string;
  pooled: boolean;
  plot: string | null;
  planted: boolean;
  ran: string[];
}

interface CliResult {
  code: number;
  stdout: string;
  stderr: string;
}

// Plain-data state shared by every extension instance: pi rebuilds the instance on each session switch.
const sharedState = globalThis as unknown as Record<symbol, Set<string> | undefined>;
const HELD = Symbol.for("orchard.pi.held");
const TRUSTED = Symbol.for("orchard.pi.trusted");
const shared = (key: symbol): Set<string> => (sharedState[key] ??= new Set<string>());

const HERE = dirname(fileURLToPath(import.meta.url));

/**
 * $ORCHARD_BIN, else the copy next to this file (the published pi-orchard package carries one), else the
 * repository's own (running from a checkout or `pi install git:…`), else `orchard` on PATH.
 */
function cliCommand(): { cmd: string; prefix: string[] } {
  if (process.env.ORCHARD_BIN) return { cmd: process.env.ORCHARD_BIN, prefix: [] };
  const bundled = [join(HERE, "bin", "orchard"), join(HERE, "..", "..", "bin", "orchard")].find((path) => existsSync(path));
  if (bundled) return { cmd: "python3", prefix: [bundled] };
  return { cmd: "orchard", prefix: [] };
}

// Not pi.exec: after a session switch the captured `pi` is stale, and `done` runs the CLI after the switch.
function runCli(args: string[], onProgress?: (line: string) => void): Promise<CliResult> {
  const { cmd, prefix } = cliCommand();
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, [...prefix, ...args], { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk;
      const last = chunk.toString().trim().split("\n").pop();
      if (last && onProgress) onProgress(last.replace(/^\[orchard\] /, ""));
    });
    child.on("error", (err: NodeJS.ErrnoException) =>
      reject(new Error(err.code === "ENOENT" ? `cannot run ${cmd}: not found (is python3 installed?)` : err.message)),
    );
    child.on("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
  });
}

const errorMessage = (err: unknown): string => (err instanceof Error ? err.message : String(err));

/** The CLI's own diagnostic lines, without the prefix. */
function diagnostics(stderr: string): string {
  return stderr
    .split("\n")
    .filter((line) => line.startsWith("[orchard]"))
    .map((line) => line.replace(/^\[orchard\] (error: )?/, ""))
    .join("\n");
}

const real = (path: string): string => {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
};

const isInside = (dir: string, root: string): boolean => {
  const d = real(dir);
  const r = real(root);
  return d === r || d.startsWith(r + sep);
};

async function readStatus(dir: string): Promise<RepoStatus> {
  const result = await runCli(["status", "--repo", dir, "--agent", "pi", "--json"]);
  if (result.code !== 0) throw new Error(diagnostics(result.stderr) || result.stderr.trim().split("\n").pop() || "orchard status failed");
  return JSON.parse(result.stdout) as RepoStatus;
}

/** The worktree `dir` is in: a pooled plot, or a plain worktree orchard created in the repo's worktrees directory. */
function locateWorktree(status: RepoStatus, dir: string): { path: string; pooled: boolean } | undefined {
  const plot = status.plots.find((p) => p.path && p.state !== "fallow" && isInside(dir, p.path));
  if (plot?.path) return { path: plot.path, pooled: true };
  const worktrees = status.worktrees_dir;
  if (!isInside(dir, worktrees)) return undefined;
  const name = real(dir).slice(real(worktrees).length + 1).split(sep)[0];
  if (!name || name.startsWith(".")) return undefined;
  return { path: join(worktrees, name), pooled: false };
}

/**
 * Move the session into `dir`, keeping the conversation. pi takes a session's working directory from the
 * header of its file, and only writes that file once a conversation exists, so a brand-new session needs
 * a header-only file written by hand.
 */
async function moveSession(
  ctx: ExtensionCommandContext,
  dir: string,
  then?: (next: ReplacedSessionContext) => Promise<void>,
): Promise<boolean> {
  await ctx.waitForIdle();
  const source = ctx.sessionManager.getSessionFile();
  let file: string | undefined;
  if (source && existsSync(source)) {
    file = SessionManager.forkFrom(source, dir).getSessionFile();
  } else {
    const fresh = SessionManager.create(dir);
    file = fresh.getSessionFile();
    if (file) {
      mkdirSync(dirname(file), { recursive: true });
      writeFileSync(file, `${JSON.stringify(fresh.getHeader())}\n`);
    }
  }
  if (!file) throw new Error("pi did not provide a session file for the new directory");
  const result = await ctx.switchSession(file, { withSession: then });
  return !result.cancelled;
}

async function giveBack(path: string): Promise<void> {
  shared(HELD).delete(path);
  await runCli(["release", path]).catch(() => undefined);
}

async function newWorktree(ctx: ExtensionCommandContext, requested: string): Promise<void> {
  const name = requested || (await ctx.ui.input("Worktree name", "e.g. login-form"));
  if (!name) return;
  if (!NAME_PATTERN.test(name)) {
    ctx.ui.notify(`"${name}" is not a usable name: use letters, digits, ".", "_" and "-"`, "error");
    return;
  }

  let claimed: Claimed;
  ctx.ui.setStatus(STATUS_KEY, `orchard: claiming ${name}…`);
  try {
    const result = await runCli(
      ["claim", name, "--repo", ctx.cwd, "--owner-pid", String(process.pid), "--agent", "pi", "--json"],
      (line) => ctx.ui.setStatus(STATUS_KEY, `orchard: ${line}`),
    );
    if (result.code !== 0) {
      ctx.ui.notify(diagnostics(result.stderr) || "orchard claim failed", "error");
      return;
    }
    claimed = JSON.parse(result.stdout) as Claimed;
  } catch (err) {
    ctx.ui.notify(errorMessage(err), "error");
    return;
  } finally {
    ctx.ui.setStatus(STATUS_KEY, undefined);
  }

  // This process now holds the plot; the session_start hook below lets go of it when the session leaves.
  shared(HELD).add(claimed.path);
  // The user is already working in a trusted project, and the plot is a checkout of the same repository.
  if (ctx.isProjectTrusted()) shared(TRUSTED).add(real(claimed.path));

  let summary = `Now in ${claimed.path} on branch ${claimed.branch}`;
  if (!claimed.pooled) summary += " (not pooled: no config for this repo, or the pool is full)";
  else if (claimed.planted) summary += ` (new plot ${claimed.plot}, prepared: ${claimed.ran.join(", ") || "nothing to run"})`;
  else if (claimed.ran.length) summary += ` (reused plot ${claimed.plot}, re-ran: ${claimed.ran.join(", ")})`;
  else summary += ` (reused plot ${claimed.plot}, everything up to date)`;

  try {
    const moved = await moveSession(ctx, claimed.path, async (next) => next.ui.notify(summary, "info"));
    if (!moved) {
      await giveBack(claimed.path);
      ctx.ui.notify("Switching sessions was cancelled; the worktree was returned.", "warning");
    }
  } catch (err) {
    await giveBack(claimed.path);
    ctx.ui.notify(`Could not move the session: ${errorMessage(err)}`, "error");
  }
}

async function doneWithWorktree(ctx: ExtensionCommandContext): Promise<void> {
  let status: RepoStatus;
  try {
    status = await readStatus(ctx.cwd);
  } catch (err) {
    ctx.ui.notify(errorMessage(err), "error");
    return;
  }
  const found = locateWorktree(status, ctx.cwd);
  if (!found) {
    ctx.ui.notify("Not inside an orchard worktree.", "warning");
    return;
  }
  if (!found.pooled) {
    const ok = await ctx.ui.confirm("Remove worktree?", `${found.path} is not in the pool, so finishing removes it (the branch is kept).`);
    if (!ok) return;
  }

  const { path } = found;
  try {
    // Leave first: releasing moves the directory out from under a session that is still in it.
    const moved = await moveSession(ctx, status.root, async (next) => {
      shared(HELD).delete(path);
      try {
        const result = await runCli(["release", path, "--json"]);
        if (result.code !== 0) {
          next.ui.notify(diagnostics(result.stderr) || "orchard release failed", "error");
          return;
        }
        const notes = diagnostics(result.stderr);
        const action = (JSON.parse(result.stdout) as { action: string }).action;
        next.ui.notify(`Back in ${status.root}; worktree ${action === "fallow" ? "returned to the pool" : "removed"}.${notes ? `\n${notes}` : ""}`, "info");
      } catch (err) {
        next.ui.notify(errorMessage(err), "error");
      }
    });
    if (!moved) ctx.ui.notify("Switching sessions was cancelled; the worktree is unchanged.", "warning");
  } catch (err) {
    ctx.ui.notify(`Could not move the session: ${errorMessage(err)}`, "error");
  }
}

async function showCli(ctx: ExtensionCommandContext, args: string[]): Promise<void> {
  try {
    const result = await runCli([...args, "--repo", ctx.cwd]);
    const text = result.stdout.trim() || diagnostics(result.stderr) || "(no output)";
    ctx.ui.notify(text, result.code === 0 ? "info" : "error");
  } catch (err) {
    ctx.ui.notify(errorMessage(err), "error");
  }
}

const HELP = [
  "/orchard new [name]   claim a worktree and move this session into it",
  "/orchard done         return the worktree to the pool and move back to the main checkout",
  "/orchard status       list plots",
  "/orchard prune [--dry-run]   reclaim finished plots of ended sessions",
].join("\n");

export default function (pi: ExtensionAPI) {
  pi.registerCommand("orchard", {
    description: "Warm git-worktree pool: new | done | status | prune",
    getArgumentCompletions: (prefix: string): AutocompleteItem[] | null => {
      const items = SUBCOMMANDS.filter((name) => name.startsWith(prefix)).map((name) => ({ value: name, label: name }));
      return items.length > 0 ? items : null;
    },
    handler: async (args, ctx) => {
      const [sub = "status", ...rest] = args.trim().split(/\s+/).filter(Boolean);
      if (sub === "new") await newWorktree(ctx, rest[0] ?? "");
      else if (sub === "done") await doneWithWorktree(ctx);
      else if (sub === "status") await showCli(ctx, ["status", "--agent", "pi"]);
      else if (sub === "prune") await showCli(ctx, ["prune", ...rest]);
      else ctx.ui.notify(HELP, "info");
    },
  });

  // A process can move between plots (/orchard new, /resume, /fork). Let go of any plot it holds but is no
  // longer in, so reclaim can judge it; otherwise a long-lived pi would keep every plot it ever visited.
  pi.on("session_start", async (_event, ctx) => {
    for (const path of [...shared(HELD)]) {
      if (isInside(ctx.cwd, path)) continue;
      shared(HELD).delete(path);
      await runCli(["disown", path]).catch(() => undefined);
    }
  });

  // Only plots this process just claimed from an already trusted project; anything else keeps pi's normal flow.
  pi.on("project_trust", (event) => (shared(TRUSTED).has(real(event.cwd)) ? { trusted: "yes" as const } : { trusted: "undecided" as const }));
}
