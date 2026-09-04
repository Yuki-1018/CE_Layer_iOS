#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: scripts/prepare_app_icon.sh path/to/icon.png" >&2
  exit 1
fi
if ! command -v sips >/dev/null 2>&1; then
  echo "sips is required (run this script on macOS)." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ICON="$1"
APPICON_DIR="$ROOT_DIR/Win95iOS/Assets.xcassets/AppIcon.appiconset"
WORK_ICON="${TMPDIR:-/tmp}/win95ios-app-icon.png"

width="$(sips -g pixelWidth "$SOURCE_ICON" | awk '/pixelWidth:/ {print $2}')"
height="$(sips -g pixelHeight "$SOURCE_ICON" | awk '/pixelHeight:/ {print $2}')"
if [[ ! "$width" =~ ^[0-9]+$ || ! "$height" =~ ^[0-9]+$ || "$width" -lt 1024 || "$height" -lt 1024 ]]; then
  echo "Custom icon must be an image of at least 1024 x 1024 pixels." >&2
  exit 1
fi

mkdir -p "$APPICON_DIR"
sips --cropToHeightWidth 1024 1024 -s format png "$SOURCE_ICON" --out "$WORK_ICON" >/dev/null

make_icon() {
  local pixels="$1"
  local filename="$2"
  sips --resampleHeightWidth "$pixels" "$pixels" "$WORK_ICON" --out "$APPICON_DIR/$filename" >/dev/null
}

make_icon 40 AppIcon-iPhone-20@2x.png
make_icon 60 AppIcon-iPhone-20@3x.png
make_icon 58 AppIcon-iPhone-29@2x.png
make_icon 87 AppIcon-iPhone-29@3x.png
make_icon 80 AppIcon-iPhone-40@2x.png
make_icon 120 AppIcon-iPhone-40@3x.png
make_icon 120 AppIcon-iPhone-60@2x.png
make_icon 180 AppIcon-iPhone-60@3x.png
make_icon 20 AppIcon-iPad-20@1x.png
make_icon 40 AppIcon-iPad-20@2x.png
make_icon 29 AppIcon-iPad-29@1x.png
make_icon 58 AppIcon-iPad-29@2x.png
make_icon 40 AppIcon-iPad-40@1x.png
make_icon 80 AppIcon-iPad-40@2x.png
make_icon 76 AppIcon-iPad-76@1x.png
make_icon 152 AppIcon-iPad-76@2x.png
make_icon 167 AppIcon-iPad-83.5@2x.png
cp "$WORK_ICON" "$APPICON_DIR/AppIcon-1024.png"

cat > "$APPICON_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "AppIcon-iPhone-20@2x.png", "idiom" : "iphone", "scale" : "2x", "size" : "20x20" },
    { "filename" : "AppIcon-iPhone-20@3x.png", "idiom" : "iphone", "scale" : "3x", "size" : "20x20" },
    { "filename" : "AppIcon-iPhone-29@2x.png", "idiom" : "iphone", "scale" : "2x", "size" : "29x29" },
    { "filename" : "AppIcon-iPhone-29@3x.png", "idiom" : "iphone", "scale" : "3x", "size" : "29x29" },
    { "filename" : "AppIcon-iPhone-40@2x.png", "idiom" : "iphone", "scale" : "2x", "size" : "40x40" },
    { "filename" : "AppIcon-iPhone-40@3x.png", "idiom" : "iphone", "scale" : "3x", "size" : "40x40" },
    { "filename" : "AppIcon-iPhone-60@2x.png", "idiom" : "iphone", "scale" : "2x", "size" : "60x60" },
    { "filename" : "AppIcon-iPhone-60@3x.png", "idiom" : "iphone", "scale" : "3x", "size" : "60x60" },
    { "filename" : "AppIcon-iPad-20@1x.png", "idiom" : "ipad", "scale" : "1x", "size" : "20x20" },
    { "filename" : "AppIcon-iPad-20@2x.png", "idiom" : "ipad", "scale" : "2x", "size" : "20x20" },
    { "filename" : "AppIcon-iPad-29@1x.png", "idiom" : "ipad", "scale" : "1x", "size" : "29x29" },
    { "filename" : "AppIcon-iPad-29@2x.png", "idiom" : "ipad", "scale" : "2x", "size" : "29x29" },
    { "filename" : "AppIcon-iPad-40@1x.png", "idiom" : "ipad", "scale" : "1x", "size" : "40x40" },
    { "filename" : "AppIcon-iPad-40@2x.png", "idiom" : "ipad", "scale" : "2x", "size" : "40x40" },
    { "filename" : "AppIcon-iPad-76@1x.png", "idiom" : "ipad", "scale" : "1x", "size" : "76x76" },
    { "filename" : "AppIcon-iPad-76@2x.png", "idiom" : "ipad", "scale" : "2x", "size" : "76x76" },
    { "filename" : "AppIcon-iPad-83.5@2x.png", "idiom" : "ipad", "scale" : "2x", "size" : "83.5x83.5" },
    { "filename" : "AppIcon-1024.png", "idiom" : "ios-marketing", "scale" : "1x", "size" : "1024x1024" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

echo "Prepared AppIcon from $SOURCE_ICON"
