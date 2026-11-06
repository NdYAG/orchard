#!/bin/bash
# Render docs/show-me-orchard.html to PNGs (desktop + phone width) for a visual check.
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DOC="file://$(cd "$(dirname "$0")/.." && pwd)/docs/show-me-orchard.html"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1100,4300 --screenshot=/tmp/orchard-doc-desktop.png "$DOC" 2>/dev/null
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=390,7600 --screenshot=/tmp/orchard-doc-phone.png "$DOC" 2>/dev/null
ls -la /tmp/orchard-doc-*.png
