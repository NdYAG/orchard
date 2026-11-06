#!/bin/sh
# Usage: scripts/release.sh <new-version>
# Bumps every version string, re-syncs the bundled copies of the CLI and runs the checks. It does not
# commit, tag or publish; the next steps are printed at the end.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
new="$1"
case "$new" in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "usage: $0 <major.minor.patch>" >&2; exit 2 ;; esac
old="$(sed -n 's/^__version__ = "\(.*\)".*/\1/p' "$root/bin/orchard")"
[ "$old" != "$new" ] || { echo "already at $new" >&2; exit 2; }

sed -i.bak "s/^__version__ = \"$old\"/__version__ = \"$new\"/" "$root/bin/orchard"
for f in package.json extensions/pi/package.json plugins/claude-code/.claude-plugin/plugin.json .claude-plugin/marketplace.json; do
  sed -i.bak "s/\"version\": \"$old\"/\"version\": \"$new\"/g" "$root/$f"
done
find "$root" -name '*.bak' -not -path '*/.git/*' -delete

"$root/scripts/sync-cli.sh"
"$root/scripts/sync-cli.sh" --check
"$root/tests/smoke.sh" >/dev/null && echo "smoke tests passed"

cat <<EOF

Bumped $old -> $new. Remaining steps:
  1. add a $new entry to CHANGELOG.md
  2. git commit, then: git tag v$new && git push --follow-tags
  3. npm publish                      (the CLI: @ndyag/orchard)
     (cd extensions/pi && npm publish)  (the pi extension: pi-orchard)
EOF
