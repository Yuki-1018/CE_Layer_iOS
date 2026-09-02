#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT_DIR/Vendor/dosbox-pure"

if [[ ! -d "$CORE_DIR/.git" ]]; then
  echo "Run scripts/fetch_core.sh first." >&2
  exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
  echo "An Xcode macOS environment is required to build the iOS core." >&2
  exit 1
fi

JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
make -C "$CORE_DIR" -j"$JOBS" \
  platform=ios-arm64 \
  STATIC_LINKING=1 \
  OUTNAME=libdosbox_pure.a \
  AR="$(xcrun --sdk iphoneos -f ar)"

test -f "$CORE_DIR/libdosbox_pure.a"

cp "$CORE_DIR/LICENSE" "$ROOT_DIR/Win95iOS/BundledContent/DOSBOX-PURE-LICENSE.txt"
cp "$CORE_DIR/DOSBOX-AUTHORS" "$ROOT_DIR/Win95iOS/BundledContent/DOSBOX-AUTHORS.txt"
cp "$CORE_DIR/DOSBOX-THANKS" "$ROOT_DIR/Win95iOS/BundledContent/DOSBOX-THANKS.txt"
