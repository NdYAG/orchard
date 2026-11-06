# orchard

A warm git-worktree pool for coding agents.

Starting a task in a fresh worktree usually means reinstalling dependencies from scratch. orchard keeps a few worktrees ("**plots**") whose dependencies are already prepared, hands one to each new task, and re-runs only the preparation steps whose inputs actually changed.

On a large JS monorepo (Claude Code 2.1.318, macOS):

| | Time |
|---|---|
| New plot (full install and build) | ~106 s |
| Reused plot, lockfile and packages changed | ~34 s |
| Reused plot, nothing changed | 0.6 s |

[Changelog](CHANGELOG.md)

## What's in the repository

One repository, one version number, three parts you can install independently:

| Part | Where | What it is |
|---|---|---|
| CLI | `bin/orchard` | The core. Works from any shell or agent. Single-file Python 3, standard library only. |
| Claude Code plugin | `plugins/claude-code` | Takes over `WorktreeCreate` / `WorktreeRemove` and adds `/orchard`. Bundles its own copy of the CLI. |
| pi extension | `extensions/pi` | Adds `/orchard new \| done \| status \| prune` and moves your pi session into a plot. |

**Requirements:** Python 3 (tested on 3.9 and 3.10) and git. [`gh`](https://cli.github.com/) is optional; it is used to check whether a branch's pull request is merged. Tested on macOS only; Windows is not supported (it uses `fcntl` and `ps`).

## Install

> orchard is not published yet. The commands below assume it will live at `<owner>/orchard`; until then, install from a local checkout.

**Claude Code**

```sh
claude plugin marketplace add <owner>/orchard
claude plugin install orchard@orchard
```

From a checkout, without installing anything: `claude --plugin-dir plugins/claude-code`.

**pi**

```sh
pi install git:github.com/<owner>/orchard
```

From a checkout: `pi -e ./extensions/pi/index.ts`.

**Command line**

```sh
scripts/install.sh        # symlinks bin/orchard into ~/.local/bin
```

## Configure a repository

orchard only pools repositories listed in `~/.config/orchard/repos.json`. The key is the path of the main checkout:

```json
{
  "~/code/app": {
    "max_plots": 4,
    "base": "origin/main",
    "fetch_ttl_minutes": 10,
    "steps": [
      { "name": "install", "fingerprint": ["pnpm-lock.yaml", ".nvmrc"], "run": "pnpm install --frozen-lockfile" },
      { "name": "build",   "fingerprint": ["packages"],                 "run": "pnpm -r build" }
    ]
  }
}
```

| Field | Meaning |
|---|---|
| `steps` | Preparation commands, run in order inside the plot. |
| `steps[].fingerprint` | Paths whose content decides whether the step must run again. Each is hashed from its git object at the target ref, together with the command itself. |
| `max_plots` | Upper bound on plots, busy ones included. When every plot is busy, orchard falls back to a plain worktree rather than blocking. Default 4. |
| `base` | Where new branches start. Default: `origin/HEAD`. |
| `worktrees_dir` | Where worktrees live, plots and the `.fallow` area included. Understands `~`, `{repo}` (the checkout's directory name) and paths relative to the checkout. Default: `.claude/worktrees`, or `.pi/worktrees` for pi (see below). |
| `fetch_ttl_minutes` | Don't `git fetch` again within this window. Default 10. |

A step runs again when its fingerprint changed, and so does every step after it. If a step fails part-way, the steps that succeeded stay recorded and the next claim resumes from the failed one.

Steps inherit the environment of whoever called orchard, so put anything version-sensitive (for example a Node version on `PATH`) into the command itself. A repository that isn't configured still gets a worktree, just not from the pool.

Monorepos usually want a build step for workspace packages. If a package's `main` points at an unbuilt `lib/`, module resolution can climb out of the worktree into the main checkout and load a second copy of a dependency such as React.

#### Where worktrees live

Each agent has a default location inside the repository:

| Caller | Default |
|---|---|
| Claude Code | `.claude/worktrees`, where Claude Code itself puts worktrees |
| pi (the extension, or `--agent pi`) | `.pi/worktrees` |
| anything else | `.claude/worktrees` |

Both sit inside the repository, so add them to your `.gitignore`; otherwise `git status` reports `.claude/` or `.pi/` as untracked. Tools that scan the whole repository (test runners, type checkers, IDE indexers) may also pick the worktrees up. A `.pi/` that holds nothing but `worktrees/` does not make pi ask whether to trust the project.

Set `worktrees_dir` to override the default for every caller, for example `"~/worktrees/{repo}"` to keep worktrees out of the project. Use `{repo}` when several repositories share a parent so the same task name in two of them can't collide. The directory must not be, or contain, the repository, and must not be inside `.git`. Without `worktrees_dir`, a plot returned to the pool is parked beside where it was, so the pool follows whichever agent used it last; with it, plots move to the configured location as they are claimed and released.

## Use

### In Claude Code

Nothing to do. Whenever Claude Code creates a worktree (the model calling `EnterWorktree` after you ask for one, `claude --worktree <name>`, or a sub-agent with worktree isolation), the plugin serves it from the pool. `/orchard` shows the pool (`/orchard status`) or reclaims finished plots (`/orchard prune`).

Claude Code only calls `WorktreeRemove` when the model runs `ExitWorktree remove`, so plots are mostly recovered by checking whether their owner has exited (see below).

### In pi

```
/orchard new [name]          claim a worktree and move this session into it, conversation included
/orchard done                move back to the main checkout and return the worktree to the pool
/orchard status
/orchard prune [--dry-run]
```

Worktrees go to `.pi/worktrees` unless `worktrees_dir` says otherwise. pi has no worktree hook. The extension forks your session into the plot's directory and switches to it, which makes pi rebuild its tools and context there. See [extensions/pi/README.md](extensions/pi/README.md).

### From the command line

```sh
orchard claim feature-x --json     # create or reuse <worktrees_dir>/feature-x (--agent pi: under .pi/worktrees)
orchard run feature-x -- pi        # claim, then exec any command inside it
orchard release <path>             # return it to the pool (uncommitted work is backed up first)
orchard disown <path>              # its owner moved on but is still running
orchard status [--json]
orchard prune [--dry-run]
orchard --version
```

`--repo DIR` (any directory inside the repository, a worktree included) selects the repository. stdout carries only the result, a path or with `--json` one JSON object; messages go to stderr and step output to `~/.cache/orchard/<repo>/orchard.log`.

## How it works

```
 claim            release / reclaim
 ─────▶ occupied ───────────────────▶ fallow ─── claim ───▶ occupied
```

- **Fallow** plots wait in `<worktrees_dir>/.fallow/<id>`. Claiming one moves it to `<worktrees_dir>/<name>` (dependencies stay in place), creates the branch from `base` without an upstream, and runs only the steps that changed.
- **Releasing** saves uncommitted work under `refs/orchard/backup/<name>-<time>` (not the shared stash), resets the plot, detaches HEAD and parks it. Branches are never deleted.
- **Ownership is a process**: its pid and start time. A plot whose owner has exited is reclaimed automatically when it is clean and its branch is merged into `base` or its pull request is merged or closed. Otherwise it is marked `stale` and listed with the reason; nothing is touched.
- **Concurrency**: a file lock covers only picking a plot and updating state. Fetching, installing and building run outside it, so parallel claims don't queue behind each other.
- A pi process can walk through several plots; `orchard disown` is how it lets go of the ones it left.

Files outside the repository: `~/.config/orchard/repos.json` and `~/.cache/orchard/<repo>/` (`pool.json`, `pool.lock`, `orchard.log`). `ORCHARD_CONFIG` and `ORCHARD_CACHE_DIR` override them.

## Development

```sh
tests/smoke.sh                     # 38 checks against a throwaway repo in /tmp/orchard-test
python3 tests/pi-e2e.py            # pi extension through `pi --mode rpc`, no model calls (run smoke.sh first)
tests/claude-e2e.sh ask "…"        # real Claude Code session; ORCHARD_INSTALLED=1 uses the installed plugin
scripts/sync-cli.sh [--check]      # keep the plugin's copy of the CLI in sync
scripts/release.sh 0.3.0           # bump every version string, sync, test
```

An installed Claude Code plugin is copied on its own into Claude Code's cache, where it can't reach the repository root, so `plugins/claude-code/bin/orchard` is a copy of `bin/orchard`. After editing the CLI run `scripts/sync-cli.sh`; `--check` also verifies that every manifest carries the same version as `__version__` in `bin/orchard`.

### Tested

Claude Code 2.1.318 and pi 1.5.0 on macOS. Worktrees outside the repository (`worktrees_dir`) were exercised with both Claude Code and pi, creating and removing. Not yet verified: installing the plugin from a GitHub marketplace (only a local-path marketplace has been exercised), and whether bumping the version updates an installed plugin.

## Status

Early. The interfaces above are what the tests cover; expect rough edges. No license has been chosen yet.
