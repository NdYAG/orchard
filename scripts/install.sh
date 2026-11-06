#!/bin/sh
# Put the orchard CLI on PATH as a symlink to this checkout (default ~/.local/bin).
set -e
repo="$(cd "$(dirname "$0")/.." && pwd)"
dest="${1:-$HOME/.local/bin}"
mkdir -p "$dest"
ln -sfn "$repo/bin/orchard" "$dest/orchard"
echo "linked $dest/orchard -> $repo/bin/orchard"
case ":$PATH:" in *":$dest:"*) ;; *) echo "note: $dest is not on PATH" ;; esac
