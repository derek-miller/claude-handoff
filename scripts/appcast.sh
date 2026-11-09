#!/bin/bash
# Prints a one-item Sparkle appcast: scripts/appcast.sh <version> <build> <dmg-url> "<sign_update output>"
set -euo pipefail
version="$1" build="$2" url="$3" signature="$4"
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
      <sparkle:releaseNotesLink>https://github.com/derek-miller/claude-handoff/releases/tag/v$version</sparkle:releaseNotesLink>
      <enclosure url="$url" type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
XML
