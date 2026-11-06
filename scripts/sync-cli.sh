#!/bin/sh
# The Claude Code plugin and the pi package are each installed or published on their own, away from the
# repository root, so each ships a copy of the CLI (and the pi package a copy of the LICENSE).
#   sync-cli.sh           refresh those copies from bin/orchard and LICENSE
#   sync-cli.sh --check   fail if a copy is stale or any manifest version disagrees with the CLI
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/bin/orchard"
copies="$root/plugins/claude-code/bin/orchard $root/extensions/pi/bin/orchard"
license_copy="$root/extensions/pi/LICENSE"

if [ "$1" != "--check" ]; then
  for dst in $copies; do
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    chmod +x "$dst"
    echo "synced $dst"
  done
  cp "$root/LICENSE" "$license_copy"
  echo "synced $license_copy"
  exit 0
fi

status=0
for dst in $copies; do
  cmp -s "$src" "$dst" || { echo "stale: $dst differs from bin/orchard (run scripts/sync-cli.sh)" >&2; status=1; }
done
cmp -s "$root/LICENSE" "$license_copy" || { echo "stale: $license_copy differs from LICENSE (run scripts/sync-cli.sh)" >&2; status=1; }
python3 - "$root" <<'PY' || status=1
import json, re, sys
root = sys.argv[1]
cli = re.search(r'^__version__ = "([^"]+)"', open(f"{root}/bin/orchard").read(), re.M).group(1)
market = json.load(open(f"{root}/.claude-plugin/marketplace.json"))
found = {
    "package.json": json.load(open(f"{root}/package.json"))["version"],
    "extensions/pi/package.json": json.load(open(f"{root}/extensions/pi/package.json"))["version"],
    "plugin.json": json.load(open(f"{root}/plugins/claude-code/.claude-plugin/plugin.json"))["version"],
    "marketplace.json metadata": market["metadata"]["version"],
    "marketplace.json plugin": market["plugins"][0]["version"],
}
bad = {k: v for k, v in found.items() if v != cli}
for k, v in bad.items():
    print(f"version mismatch: {k} is {v}, bin/orchard is {cli}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
[ "$status" = 0 ] && echo "ok: copies in sync, all versions $(sed -n 's/^__version__ = "\(.*\)".*/\1/p' "$src")"
exit $status
