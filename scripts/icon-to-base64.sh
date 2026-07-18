#!/bin/bash
# Convert an image, SF Symbol, or emoji into a base64 PNG string ready to
# paste into an MTMR items.json "image": { "base64": "..." } field.
#
# Usage:
#   icon-to-base64.sh --image /path/to/icon.png [--size 44]
#   icon-to-base64.sh --sf-symbol "wrench.and.screwdriver" [--color white] [--size 44] [--point-size 32]
#   icon-to-base64.sh --emoji "🔥" [--size 44]
#
# Defaults render at 2x (44x44px / point-size 32) because the Touch Bar is a
# Retina (2x) display — MTMR displays icons around ~22pt, and a 1x (22x22px)
# source gets visibly upscaled/blurred by the OS to fill that at 2x density.
# Rendering at 44x44px physical pixels for a 22pt visual size keeps it crisp.
# If you deliberately want a smaller/non-Retina icon, pass --size/--point-size
# explicitly (e.g. --size 22 --point-size 16 for the old 1x behavior).
#
# Always re-encodes to a clean 8-bit RGBA PNG (MTMR crashes on 8-bit
# indexed/palette PNGs) and copies the base64 result to your clipboard,
# in addition to printing it to stdout.

set -euo pipefail

SIZE=44
POINT_SIZE=32
COLOR="white"
MODE=""
INPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) MODE="image"; INPUT="$2"; shift 2 ;;
    --sf-symbol) MODE="sf-symbol"; INPUT="$2"; shift 2 ;;
    --emoji) MODE="emoji"; INPUT="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --point-size) POINT_SIZE="$2"; shift 2 ;;
    --color) COLOR="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "Usage: icon-to-base64.sh --image <path> | --sf-symbol <name> | --emoji <emoji> [--size N] [--color name] [--point-size N]" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
RAW_PNG="$WORKDIR/raw.png"
CLEAN_PNG="$WORKDIR/clean.png"

case "$MODE" in
  image)
    if [ ! -f "$INPUT" ]; then
      echo "File not found: $INPUT" >&2
      exit 1
    fi
    cp "$INPUT" "$RAW_PNG"
    ;;

  sf-symbol)
    cat > "$WORKDIR/gen.swift" << EOF
import AppKit

func namedColor(_ name: String) -> NSColor {
    switch name.lowercased() {
    case "white": return .white
    case "black": return .black
    case "red": return .systemRed
    case "orange": return .systemOrange
    case "yellow": return .systemYellow
    case "green": return .systemGreen
    case "blue": return .systemBlue
    case "purple": return .systemPurple
    case "gray", "grey": return .systemGray
    default:
        // accept a "#RRGGBB" hex string
        if name.hasPrefix("#"), name.count == 7,
           let rgb = UInt32(name.dropFirst(), radix: 16) {
            let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
            let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
            let b = CGFloat(rgb & 0xFF) / 255.0
            return NSColor(red: r, green: g, blue: b, alpha: 1.0)
        }
        return .white
    }
}

let size = NSSize(width: $SIZE, height: $SIZE)
let pointConfig = NSImage.SymbolConfiguration(pointSize: $POINT_SIZE, weight: .medium)
let colorConfig = NSImage.SymbolConfiguration(paletteColors: [namedColor("$COLOR")])
guard let symbolImage = NSImage(systemSymbolName: "$INPUT", accessibilityDescription: nil) else {
    FileHandle.standardError.write("failed to load SF Symbol: $INPUT\n".data(using: .utf8)!)
    exit(1)
}
guard let configured = symbolImage.withSymbolConfiguration(pointConfig.applying(colorConfig)) else {
    exit(1)
}
let finalImage = NSImage(size: size)
finalImage.lockFocus()
let rect = NSRect(x: (size.width - configured.size.width) / 2, y: (size.height - configured.size.height) / 2, width: configured.size.width, height: configured.size.height)
configured.draw(in: rect)
finalImage.unlockFocus()
let tiff = finalImage.tiffRepresentation!
let bitmap = NSBitmapImageRep(data: tiff)!
let pngData = bitmap.representation(using: .png, properties: [:])!
try! pngData.write(to: URL(fileURLWithPath: "$RAW_PNG"))
EOF
    swift "$WORKDIR/gen.swift"
    ;;

  emoji)
    cat > "$WORKDIR/gen.swift" << EOF
import AppKit
let size = NSSize(width: $SIZE, height: $SIZE)
let finalImage = NSImage(size: size)
finalImage.lockFocus()
let font = NSFont.systemFont(ofSize: CGFloat($POINT_SIZE) + 4)
let attrs: [NSAttributedString.Key: Any] = [.font: font]
let str = NSAttributedString(string: "$INPUT", attributes: attrs)
let strSize = str.size()
let point = NSPoint(x: (size.width - strSize.width) / 2, y: (size.height - strSize.height) / 2)
str.draw(at: point)
finalImage.unlockFocus()
let tiff = finalImage.tiffRepresentation!
let bitmap = NSBitmapImageRep(data: tiff)!
let pngData = bitmap.representation(using: .png, properties: [:])!
try! pngData.write(to: URL(fileURLWithPath: "$RAW_PNG"))
EOF
    swift "$WORKDIR/gen.swift"
    ;;
esac

# Always re-encode to clean 8-bit RGBA (avoids MTMR's indexed-PNG crash bug)
sips -s format png -z "$SIZE" "$SIZE" "$RAW_PNG" --out "$CLEAN_PNG" >/dev/null 2>&1

B64=$(base64 -i "$CLEAN_PNG" | tr -d '\n')
echo "$B64" | pbcopy
echo "$B64"
echo "" >&2
echo "(${#B64} chars, copied to clipboard, ${SIZE}x${SIZE} RGBA PNG)" >&2
