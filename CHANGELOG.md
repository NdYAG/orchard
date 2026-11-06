# Changelog

## 0.2.0

- Split into an agent-neutral CLI (`bin/orchard`) and adapters: the Claude Code plugin (`plugins/claude-code`) and the pi extension (`extensions/pi`: `/orchard new | done | status | prune`).
- `status --json` reports each plot's `owner_pid` and the `worktrees_dir`.
- Worktrees default to `.claude/worktrees` for Claude Code and `.pi/worktrees` for pi (`--agent pi`, which `claim` and `status` accept); a plot returned to the pool is parked beside where it was.
- `worktrees_dir` setting: keep worktrees somewhere other than `.claude/worktrees` (outside the repository, for instance). `release` and `disown` no longer need the path to exist inside a repository.
- CLI: `claim`, `release`, `disown`, `run`, `status`, `prune` with `--json`; `hook claude-create|claude-remove` for Claude Code; `--version`.
- The Claude Code plugin bundles its own copy of the CLI and is installable from the repo as a marketplace.
- Published as `@ndyag/orchard` (the CLI) and `pi-orchard` (the pi extension, with its own copy of the CLI). MIT licensed.
- Preparation is a list of fingerprinted `steps`; only the first changed step and those after it re-run.

## 0.1.0

- Prototype: Claude Code plugin with a single `prepare` command.
