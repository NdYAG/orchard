# Changelog

## 0.2.0

- Split into an agent-neutral CLI (`bin/orchard`) and adapters: the Claude Code plugin (`plugins/claude-code`); the pi extension (`extensions/pi`) is not written yet.
- CLI: `claim`, `release`, `disown`, `run`, `status`, `prune` with `--json`; `hook claude-create|claude-remove` for Claude Code; `--version`.
- The Claude Code plugin bundles its own copy of the CLI and is installable from the repo as a marketplace.
- Preparation is a list of fingerprinted `steps`; only the first changed step and those after it re-run.

## 0.1.0

- Prototype: Claude Code plugin with a single `prepare` command.
