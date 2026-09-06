#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/win9x-bundled-disk-test.XXXXXX")"
RAW_SOURCE="$TEST_ROOT/raw-source"
VHD_SOURCE="$TEST_ROOT/vhd-source"

truncate -s 10485760 "$RAW_SOURCE"
BUNDLED_DISK_OUTPUT_DIR="$TEST_ROOT/raw-output" \
  "$(dirname "$0")/prepare_bundled_disk.sh" "$RAW_SOURCE" auto
test -f "$TEST_ROOT/raw-output/win95-base.img"

truncate -s 10485760 "$VHD_SOURCE"
printf conectix | dd of="$VHD_SOURCE" bs=1 seek=10485248 conv=notrunc 2>/dev/null
BUNDLED_DISK_OUTPUT_DIR="$TEST_ROOT/vhd-output" \
  "$(dirname "$0")/prepare_bundled_disk.sh" "$VHD_SOURCE" auto
test -f "$TEST_ROOT/vhd-output/win95-base.vhd"

if BUNDLED_DISK_OUTPUT_DIR="$TEST_ROOT/invalid-output" \
  "$(dirname "$0")/prepare_bundled_disk.sh" "$RAW_SOURCE" vhd 2>/dev/null; then
  echo "Raw image was incorrectly accepted as VHD." >&2
  exit 1
fi

echo "PASS: bundled raw IMG and VHD preparation"
