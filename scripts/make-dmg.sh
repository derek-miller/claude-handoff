#!/bin/bash
# Packages dist/Claude Handoff.app into a drag-to-Applications DMG: scripts/make-dmg.sh dist/Claude-Handoff-1.2.3.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
out="$1"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "dist/Claude Handoff.app" "$stage/Claude Handoff.app"
ln -s /Applications "$stage/Applications"
rm -f "$out"
hdiutil create -volname "Claude Handoff" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$out"
