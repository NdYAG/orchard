#!/bin/bash
# End-to-end smoke test for bin/orchard, isolated under /tmp/orchard-test.
# Sections 1-10 drive it through the Claude Code adapter (shim + hook JSON); 11 uses the plain CLI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORCHARD="$ROOT/bin/orchard"
SHIM="$ROOT/plugins/claude-code/bin/orchard-shim"
unset ORCHARD_BIN
"$ROOT/scripts/sync-cli.sh" --check >/dev/null || { echo "plugin's CLI copy is stale: run scripts/sync-cli.sh" >&2; exit 1; }
T=/tmp/orchard-test
rm -rf "$T"; mkdir -p "$T"
export ORCHARD_CONFIG="$T/config/orchard/repos.json" ORCHARD_CACHE_DIR="$T/cache/orchard"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

pass() { printf '  \033[32mok\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

git init -q --bare -b master "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
R=$(cd "$T/repo" && pwd -P)
echo v1 >"$R/deps.lock"; echo node_modules/ >"$R/.gitignore"; mkdir "$R/pkg"; echo a >"$R/pkg/src"
git -C "$R" add -A; git -C "$R" commit -qm init; git -C "$R" push -q origin master
git -C "$R" remote set-head origin master

mkdir -p "$(dirname "$ORCHARD_CONFIG")"
cat >"$ORCHARD_CONFIG" <<EOF
{ "$R": { "max_plots": 2, "fetch_ttl_minutes": 0, "steps": [
  { "name": "install", "fingerprint": ["deps.lock"],
    "run": "mkdir -p node_modules && echo \$(cat deps.lock) >> node_modules/installs" },
  { "name": "build", "fingerprint": ["pkg"], "run": "cat pkg/src >> node_modules/builds" } ] } }
EOF

# A dead PID with a recorded start time never matches; a live one is this shell.
sleep 0 & DEAD=$!; wait $DEAD
claim() { # name pid
  printf '{"name":"%s","cwd":"%s","session_id":"s-%s","hook_event_name":"WorktreeCreate"}' "$1" "$R" "$1" |
    CLAUDE_PID=$2 "$SHIM" hook claude-create
}
release() { printf '{"worktree_path":"%s"}' "$1" | "$SHIM" hook claude-remove; }
installs() { wc -l <"$1/node_modules/installs" | tr -d ' '; }
builds() { wc -l <"$1/node_modules/builds" | tr -d ' '; }

echo "1. plant + prepare"
P=$(claim a1 $$ 2>/dev/null)
check "path printed on stdout" test "$P" = "$R/.claude/worktrees/a1"
check "branch a1 checked out" test "$(git -C "$P" branch --show-current)" = a1
check "branch has no upstream" bash -c "! git -C '$P' rev-parse --abbrev-ref a1@{upstream} 2>/dev/null"
check "prepared once" test "$(installs "$P")" = 1

echo "2. release parks the plot with its dependencies"
release "$P" 2>/dev/null
check "moved to .fallow/p1" test -d "$R/.claude/worktrees/.fallow/p1/node_modules"
check "a1 directory gone" test ! -e "$P"
check "branch a1 kept" git -C "$R" show-ref --verify --quiet refs/heads/a1

echo "3. reuse skips prepare when the lockfile is unchanged"
P=$(claim a2 $$ 2>/dev/null)
check "reused into a2" test "$P" = "$R/.claude/worktrees/a2"
check "still one install" test "$(installs "$P")" = 1
check "on branch a2" test "$(git -C "$P" branch --show-current)" = a2

echo "4. reuse re-prepares when the lockfile changed upstream"
echo v2 >"$R/deps.lock"; git -C "$R" commit -qam bump; git -C "$R" push -q origin master
release "$P" 2>/dev/null
P=$(claim a3 $$ 2>/dev/null)
check "second install ran" test "$(installs "$P")" = 2
check "a later step re-runs after an earlier one" test "$(builds "$P")" = 2
check "a3 starts from new master" test "$(cat "$P/deps.lock")" = v2

echo "4b. a change under pkg/ re-runs only the build step"
echo b >"$R/pkg/src"; git -C "$R" commit -qam pkg; git -C "$R" push -q origin master
release "$P" 2>/dev/null
P=$(claim a4 $$ 2>/dev/null)
check "install skipped" test "$(installs "$P")" = 2
check "build re-ran" test "$(builds "$P")" = 3
OLD=$P; release "$P" 2>/dev/null; P=$(claim a3b $$ 2>/dev/null)
check "nothing re-ran when up to date" test "$(builds "$P"):$(installs "$P")" = 3:2

echo "5. dirty release is backed up, not lost"
echo wip >"$P/wip.txt"; echo edit >>"$P/deps.lock"
release "$P" 2>/dev/null
REF=$(git -C "$R" for-each-ref --format='%(refname)' 'refs/orchard/backup/a3b-*')
check "backup ref created" test -n "$REF"
check "backup holds untracked file" test "$(git -C "$R" show "$REF:wip.txt")" = wip
check "fallow plot is clean" test -z "$(git -C "$R/.claude/worktrees/.fallow/p1" status --porcelain)"

echo "6. prune reclaims a finished plot of an ended session, keeps live ones"
PC=$(claim c1 $$ 2>/dev/null)  # live owner first; claiming would itself reclaim a dead b1
PB=$(claim b1 $DEAD 2>/dev/null)
OUT=$(python3 "$ORCHARD" prune --cwd "$R")
echo "$OUT" | sed 's/^/     /'
check "b1 reclaimed (contained in base)" grep -q "reclaimed: contained in" <<<"$OUT"
check "c1 untouched" test -d "$PC"

echo "7. ended session with unfinished work becomes stale"
PB=$(claim b2 $DEAD 2>/dev/null)
echo x >"$PB/x"; git -C "$PB" add x; git -C "$PB" commit -qm wip
OUT=$(python3 "$ORCHARD" prune --cwd "$R")
check "b2 kept with a reason" grep -q "b2.*kept" <<<"$OUT"
check "b2 directory still there" test -d "$PB"

echo "8. pool exhausted falls back to a plain worktree"
P=$(claim d1 $$ 2>/dev/null)
check "plain worktree created" test -d "$P"
check "no dependencies in plain worktree" test ! -e "$P/node_modules"
release "$P" 2>/dev/null
check "unmanaged worktree removed on release" test ! -e "$P"

echo "9. unconfigured repo uses Claude Code's default naming"
git clone -q "$T/origin.git" "$T/other" 2>/dev/null
O=$(cd "$T/other" && pwd -P)
P=$(printf '{"name":"z1","cwd":"%s"}' "$O" | "$SHIM" hook claude-create 2>/dev/null)
check "branch worktree-z1" test "$(git -C "$P" branch --show-current)" = worktree-z1
P=$(python3 "$ORCHARD" claim z2 --repo "$O" 2>/dev/null)
check "plain CLI keeps the name as branch" test "$(git -C "$P" branch --show-current)" = z2

echo "10. concurrent claims never share a plot"
release "$PC" 2>/dev/null
python3 - "$ORCHARD_CONFIG" "$R" <<'PY'
import json, sys
path, root = sys.argv[1], sys.argv[2]
cfg = json.load(open(path)); cfg[root]["max_plots"] = 5; json.dump(cfg, open(path, "w"))
PY
for n in 1 2 3 4; do (claim e$n $$ >"$T/e$n.out" 2>/dev/null) & done; wait
PATHS=$(cat "$T"/e*.out | sort -u | wc -l | tr -d ' ')
check "4 distinct paths" test "$PATHS" = 4
IDS=$(python3 -c "import json,glob; p=json.load(open(glob.glob('$ORCHARD_CACHE_DIR/*/pool.json')[0])); print(len({x['path'] for x in p['plots'] if x['state']=='occupied'}))")
check "pool records each plot once" test "$IDS" -ge 4

echo "11. agent-neutral CLI: claim --json, disown, run, status --json"
for n in 1 2 3 4; do python3 "$ORCHARD" release "$(cat "$T/e$n.out")" >/dev/null 2>&1; done
J=$(python3 "$ORCHARD" claim g1 --repo "$R" --owner-pid $$ --agent pi --json 2>/dev/null)
field() { python3 -c "import json,sys; print(json.loads(sys.argv[1])$2)" "$1"; }
G1=$(field "$J" "['path']")
check "claim --json gives the path" test "$G1" = "$R/.claude/worktrees/g1"
check "claim --json says it was pooled" test "$(field "$J" "['pooled']")" = True
S=$(python3 "$ORCHARD" status --repo "$R" --json)
check "status --json records the agent" grep -q '"agent": "pi"' <<<"$S"
OUT=$(python3 "$ORCHARD" prune --repo "$R")
check "a live owner keeps g1" test -d "$G1"
python3 "$ORCHARD" disown "$G1" >/dev/null
OUT=$(python3 "$ORCHARD" prune --repo "$R")
check "after disown, prune reclaims g1" grep -q "g1.*reclaimed" <<<"$OUT"
RUN=$(python3 "$ORCHARD" run h1 --repo "$R" -- sh -c 'echo "$PWD|$ORCHARD_WORKTREE|$$"' 2>/dev/null)
check "run execs inside the worktree" test "${RUN%%|*}" = "$R/.claude/worktrees/h1"
OWNER=$(python3 -c "import json,glob; p=json.load(open(glob.glob('$ORCHARD_CACHE_DIR/*/pool.json')[0])); print([x['owner']['pid'] for x in p['plots'] if x.get('name')=='h1'][0])")
check "run makes the exec'd process the owner" test "$OWNER" = "${RUN##*|}"
R2=$(python3 "$ORCHARD" release "$R/.claude/worktrees/h1" --json)
check "release --json reports fallow" test "$(field "$R2" "['action']")" = fallow

echo
python3 "$ORCHARD" status --repo "$R"
echo; echo "all smoke checks passed"
