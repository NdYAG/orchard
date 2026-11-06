#!/bin/bash
# Drive real Claude Code sessions against the smoke-test repo with the plugin loaded via --plugin-dir.
# Usage: claude-e2e.sh exit <name> | ask "<prompt>" | cmd "/orchard status" | agent   (run tests/smoke.sh first)
# ORCHARD_E2E_WRAPPER="<cmd> --" prefixes every claude call, for setups that need a credential wrapper.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)/plugins/claude-code"
PLUGIN_ARGS=(--plugin-dir "$PLUGIN")  # ORCHARD_INSTALLED=1: rely on the installed plugin instead
[ -n "${ORCHARD_INSTALLED:-}" ] && PLUGIN_ARGS=()
T=/tmp/orchard-test
export ORCHARD_CONFIG="$T/config/orchard/repos.json" ORCHARD_CACHE_DIR="$T/cache/orchard"
cd "$T/repo" || exit 1
case "$1" in
  exit)
    ${ORCHARD_E2E_WRAPPER:-} claude -p ${PLUGIN_ARGS[@]+"${PLUGIN_ARGS[@]}"} --debug --debug-file "$T/debug-$2.log" \
      --worktree "$2" --max-turns 5 --allowedTools=ExitWorktree,ToolSearch,Bash \
      "Run pwd. Then call ExitWorktree with action remove and discard_changes true (nothing important here). Report pwd and the tool result." ;;
  cmd)
    shift
    ${ORCHARD_E2E_WRAPPER:-} claude -p ${PLUGIN_ARGS[@]+"${PLUGIN_ARGS[@]}"} --debug --debug-file "$T/debug-cmd.log" \
      --max-turns 2 --allowedTools=Skill "$*" ;;
  ask)
    # A natural-language request, no --worktree flag: does the model's own EnterWorktree reach the hook?
    shift
    ${ORCHARD_E2E_WRAPPER:-} claude -p ${PLUGIN_ARGS[@]+"${PLUGIN_ARGS[@]}"} --debug --debug-file "$T/debug-ask.log" \
      --max-turns 6 --allowedTools=EnterWorktree,ToolSearch,Bash "$*" ;;
  agent)
    ${ORCHARD_E2E_WRAPPER:-} claude -p ${PLUGIN_ARGS[@]+"${PLUGIN_ARGS[@]}"} --debug --debug-file "$T/debug-agent.log" \
      --max-turns 4 --allowedTools=Agent,Bash \
      "Spawn one subagent with isolation set to worktree. Ask it to run pwd and report it, without modifying files. Report what it said." ;;
esac
