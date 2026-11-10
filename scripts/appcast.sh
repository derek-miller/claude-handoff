#!/bin/bash
# Prints a one-item Sparkle appcast with the release notes inlined:
#   scripts/appcast.sh <version> <build> <dmg-url> "<sign_update output>" <notes.md> <release-url>
set -euo pipefail
version="$1" build="$2" url="$3" signature="$4" notes="$5" release="$6"
description="$(python3 - "$notes" "$release" <<'PY'
import html, re, sys
items = []
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("## ") and items:
        break
    m = re.match(r"\s*[*-]\s+(.*)", line)
    if not m:
        continue
    text = re.sub(r"\s+by @\S+ in https://\S+$", "", m.group(1).strip())
    items.append(f"<li>{html.escape(text)}</li>")
body = f"<ul>{''.join(items)}</ul>" if items else "<p>Fixes and improvements.</p>"
style = "body{font:13px -apple-system,sans-serif;color-scheme:light dark;margin:12px}h3{margin:0 0 6px}ul{padding-left:18px;margin:0 0 10px}"
print(f"<style>{style}</style><h3>What's new</h3>{body}"
      f"<p><a href=\"{html.escape(sys.argv[2])}\">Full release notes</a></p>")
PY
)"
cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Claude Handoff</title>
    <item>
      <title>Version $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$description]]></description>
      <enclosure url="$url" type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
XML
