#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 path/to/win95-base.img" >&2
  exit 2
fi

DISK="$1"
if [[ ! -f "$DISK" ]]; then
  echo "Disk image not found: $DISK" >&2
  exit 1
fi

size="$(wc -c < "$DISK" | tr -d ' ')"
if (( size < 10485760 )); then
  echo "Disk image is unexpectedly small ($size bytes)." >&2
  exit 1
fi
if (( size % 512 != 0 )); then
  echo "Disk image size must be a multiple of 512 bytes." >&2
  exit 1
fi

echo "Disk image looks structurally valid: $size bytes ($((size / 512)) sectors)."

