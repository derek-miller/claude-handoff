#!/bin/bash
# Builds a universal "Claude Handoff.app" into dist/.
#   VERSION=1.2.3 BUILD=42 SPARKLE_PUBLIC_KEY=... SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
# Without SIGN_IDENTITY the app is ad-hoc signed (fine for local testing, not for distribution).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
BUILD="${BUILD:-1}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="dist/Claude Handoff.app"

printf '// Written by scripts/build-app.sh from the release tag.\npublic enum HandoffVersion {\n    public static let current = "%s"\n}\n' "$VERSION" > Sources/HandoffCore/Engine/Version.swift
trap 'git checkout -- Sources/HandoffCore/Engine/Version.swift 2>/dev/null || true' EXIT

swift build -c release --arch arm64 --arch x86_64 --product ClaudeHandoff
swift build -c release --arch arm64 --arch x86_64 --product claude-handoff
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
SPARKLE="$(find .build/artifacts -path '*macos-arm64_x86_64/Sparkle.framework' -maxdepth 6 | head -1)"
[ -d "$SPARKLE" ] || { echo "Sparkle.framework not found under .build/artifacts" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/ClaudeHandoff" "$APP/Contents/MacOS/Claude Handoff"
cp "$BIN/claude-handoff" "$APP/Contents/MacOS/claude-handoff"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s|__SPARKLE_PUBLIC_KEY__|$SPARKLE_PUBLIC_KEY|" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Inside-out signing; Sparkle's helpers need the hardened runtime too (https://sparkle-project.org/documentation/sandboxing/).
sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@"; }
[ "$SIGN_IDENTITY" = "-" ] && sign() { codesign --force --sign - "$@"; }
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$FW/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
sign "$FW/Autoupdate"
sign "$FW/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP/Contents/MacOS/claude-handoff"
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "built $APP ($VERSION)"
