# orchard for pi

A pi extension that adds `/orchard` and moves your pi session into a worktree from the orchard pool.

| Command | What it does |
|---|---|
| `/orchard new [name]` | Claim a worktree (reusing a prepared one when possible) and move this session into it, conversation included. |
| `/orchard done` | Move back to the main checkout and return the worktree to the pool. Uncommitted work is saved under `refs/orchard/backup/`. |
| `/orchard status` | List the pool's plots. |
| `/orchard prune [--dry-run]` | Reclaim finished plots whose owner has exited. |

## Install

```sh
pi install npm:<package>              # once published
pi install git:github.com/<owner>/orchard
pi -e ./extensions/pi/index.ts        # try it from a checkout
```

The extension runs the orchard CLI shipped in the same package (`bin/orchard`, needs `python3`). Set `ORCHARD_BIN` to use another one. The repository must be configured in `~/.config/orchard/repos.json`; otherwise `/orchard new` still creates a worktree, just not from the pool.

## How it works

pi has no worktree hook. It does take a session's working directory from the header of the session file, and switching to a session in another directory rebuilds the tools, `AGENTS.md` and shell there. So `/orchard new` runs `orchard claim`, forks the current session into the plot's directory (or writes a header-only session file when there is no conversation yet), and switches to it. `/orchard done` does the same in reverse, then runs `orchard release`.

A pi process can visit several plots. On every session start the extension hands back (`orchard disown`) any plot this process holds but is no longer in, so `orchard prune` can judge it.

If you already trusted the project, plots claimed from it are trusted automatically (a `project_trust` handler); otherwise pi would ask again for every new directory.

Tested with pi 1.5.0 (`tests/pi-e2e.py`).
