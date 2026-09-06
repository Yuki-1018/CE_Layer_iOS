#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 path/to/win95-base-CDRIVE.sav" >&2
  exit 2
fi

SOURCE_SAVE="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_DIR="${BUNDLED_DISK_OUTPUT_DIR:-$ROOT_DIR/Win95iOS/BundledContent}"

if [[ ! -f "$SOURCE_SAVE" ]]; then
  echo "HDD save not found: $SOURCE_SAVE" >&2
  exit 1
fi

SAVE_SIZE="$(wc -c < "$SOURCE_SAVE" | tr -d ' ')"
if (( SAVE_SIZE < 5 )); then
  echo "HDD save is shorter than the FFDD header." >&2
  exit 1
fi
if (( SAVE_SIZE >= 4294966779 )); then
  echo "HDD save exceeds the FFDD v1 size limit." >&2
  exit 1
fi

HEADER_HEX="$(dd if="$SOURCE_SAVE" bs=1 count=5 2>/dev/null | od -An -tx1 | tr -d ' \n')"
if [[ "$HEADER_HEX" != 4646444401 ]]; then
  echo "HDD save has an invalid FFDD v1 header." >&2
  exit 1
fi

# FFDD v1 consists of a five-byte header followed by records containing a
# four-byte little-endian sector number and one 512-byte sector payload.
if (( (SAVE_SIZE - 5) % 516 != 0 )); then
  echo "HDD save ends with an incomplete FFDD record." >&2
  exit 1
fi

mkdir -p "$BUNDLE_DIR"
DESTINATION="$BUNDLE_DIR/win95-base-CDRIVE.sav"
if [[ "$SOURCE_SAVE" != "$DESTINATION" ]]; then
  cp "$SOURCE_SAVE" "$DESTINATION"
fi
echo "Bundled HDD save prepared: $DESTINATION"
