#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 path/to/disk-image auto|img|vhd" >&2
  exit 2
fi

SOURCE_DISK="$1"
REQUESTED_FORMAT="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_DIR="${BUNDLED_DISK_OUTPUT_DIR:-$ROOT_DIR/Win95iOS/BundledContent}"

if [[ ! -f "$SOURCE_DISK" ]]; then
  echo "HDD image not found: $SOURCE_DISK" >&2
  exit 1
fi
if [[ "$REQUESTED_FORMAT" != auto && "$REQUESTED_FORMAT" != img && "$REQUESTED_FORMAT" != vhd ]]; then
  echo "HDD image format must be auto, img, or vhd." >&2
  exit 1
fi

DISK_SIZE="$(wc -c < "$SOURCE_DISK" | tr -d ' ')"
if (( DISK_SIZE < 10485760 || DISK_SIZE % 512 != 0 )); then
  echo "HDD image must be at least 10 MiB and a multiple of 512 bytes." >&2
  exit 1
fi

VHD_COOKIE_HEX=""
if (( DISK_SIZE >= 512 )); then
  VHD_COOKIE_HEX="$(dd if="$SOURCE_DISK" bs=1 skip=$((DISK_SIZE - 512)) count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')"
fi

DISK_FORMAT="$REQUESTED_FORMAT"
if [[ "$DISK_FORMAT" == auto ]]; then
  if [[ "$VHD_COOKIE_HEX" == 636f6e6563746978 ]]; then DISK_FORMAT=vhd; else DISK_FORMAT=img; fi
fi
if [[ "$DISK_FORMAT" == vhd && "$VHD_COOKIE_HEX" != 636f6e6563746978 ]]; then
  echo "The selected file has no valid VHD footer. Select img for a raw image." >&2
  exit 1
fi

mkdir -p "$BUNDLE_DIR"
DESTINATION="$BUNDLE_DIR/win-base.$DISK_FORMAT"
OTHER_FORMAT=img
if [[ "$DISK_FORMAT" == img ]]; then OTHER_FORMAT=vhd; fi
OTHER_DESTINATION="$BUNDLE_DIR/win-base.$OTHER_FORMAT"
if [[ -e "$OTHER_DESTINATION" ]]; then
  echo "Another bundled HDD already exists: $OTHER_DESTINATION" >&2
  exit 1
fi

if [[ "$SOURCE_DISK" != "$DESTINATION" ]]; then
  cp "$SOURCE_DISK" "$DESTINATION"
fi
"$ROOT_DIR/scripts/validate_disk.sh" "$DESTINATION"
echo "Bundled $DISK_FORMAT HDD prepared: $DESTINATION"
