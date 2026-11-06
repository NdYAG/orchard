#!/bin/sh
# An installed Claude Code plugin is copied alone into its cache, so it ships its own copy of the CLI.
#   sync-cli.sh           copy bin/orchard into plugins/claude-code/bin/
#   sync-cli.sh --check   fail if that copy is stale or any manifest version disagrees with the CLI
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/bin/orchard"
dst="$root/plugins/claude-code/bin/orchard"

if [ "$1" != "--check" ]; then
  cp "$src" "$dst"
  chmod +x "$dst"
  echo "synced $dst"
  exit 0
fi

status=0
cmp -s "$src" "$dst" || { echo "stale: $dst differs from bin/orchard (run scripts/sync-cli.sh)" >&2; status=1; }
python3 - "$root" <<'PY' || status=1
import json, re, sys
root = sys.argv[1]
cli = re.search(r'^__version__ = "([^"]+)"', open(f"{root}/bin/orchard").read(), re.M).group(1)
market = json.load(open(f"{root}/.claude-plugin/marketplace.json"))
found = {
    "package.json": json.load(open(f"{root}/package.json"))["version"],
    "plugin.json": json.load(open(f"{root}/plugins/claude-code/.claude-plugin/plugin.json"))["version"],
    "marketplace.json metadata": market["metadata"]["version"],
    "marketplace.json plugin": market["plugins"][0]["version"],
}
bad = {k: v for k, v in found.items() if v != cli}
for k, v in bad.items():
    print(f"version mismatch: {k} is {v}, bin/orchard is {cli}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
[ "$status" = 0 ] && echo "ok: CLI copy in sync, all versions $(sed -n 's/^__version__ = "\(.*\)".*/\1/p' "$src")"
exit $status
