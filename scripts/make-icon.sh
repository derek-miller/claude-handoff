#!/bin/bash
# Renders Resources/AppIcon.svg into Resources/AppIcon.icns: scripts/make-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
set=$work/AppIcon.iconset; mkdir "$set"
cat > "$work/render.swift" <<'EOF'
import AppKit
let args = CommandLine.arguments
let source = NSImage(contentsOfFile: args[1])!
for spec in args[3...] {
    let parts = spec.split(separator: ":"), name = String(parts[0]), px = Int(parts[1])!
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]).appendingPathComponent(name))
}
EOF
specs=()
for s in 16 32 128 256 512; do specs+=("icon_${s}x${s}.png:$s" "icon_${s}x${s}@2x.png:$((s * 2))"); done
swift "$work/render.swift" Resources/AppIcon.svg "$set" "${specs[@]}"
iconutil -c icns "$set" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
