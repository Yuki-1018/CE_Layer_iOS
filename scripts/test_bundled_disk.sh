#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/win9x-bundled-disk-test.XXXXXX")"
RAW_SOURCE="$TEST_ROOT/raw-source"
VHD_SOURCE="$TEST_ROOT/vhd-source"
SAVE_SOURCE="$TEST_ROOT/save-source.sav"

truncate -s 10485760 "$RAW_SOURCE"
BUNDLED_DISK_OUTPUT_DIR="$TEST_ROOT/raw-output" \
  "$(dirname "$0")/prepare_bundled_disk.sh" "$RAW_SOURCE" auto
test -f "$TEST_ROOT/raw-output/win-base.img"

truncate -s 10485760 "$VHD_SOURCE"
printf conectix | dd of="$VHD_SOURCE" bs=1 seek=10485248 conv=notrunc 2>/dev/null
BUNDLED_DISK_OUTPUT_DIR="$TEST_ROOT/vhd-output" \
  "$(dirname "$0")/prepare_bundled_disk.sh" "$VHD_SOURCE" auto
test -f "$TEST_ROOT/vhd-output/win-base.vhd"

printf 'FFDD\001' > "$SAVE_SOURCE"
dd if=/dev/zero bs=516 count=1 >> "$SAVE_SOURCE" 2>/dev/null
BUNDLED_DISK_OUTPUT_DIR="$TEST_ROOT/save-output" \
  "$(dirname "$0")/prepare_bundled_save.sh" "$SAVE_SOURCE"
cmp "$SAVE_SOURCE" "$TEST_ROOT/save-output/win-base-CDRIVE.sav"

printf 'not-a-save' > "$TEST_ROOT/invalid-save"
if BUNDLED_DISK_OUTPUT_DIR="$TEST_ROOT/invalid-save-output" \
  "$(dirname "$0")/prepare_bundled_save.sh" "$TEST_ROOT/invalid-save" 2>/dev/null; then
  echo "Invalid FFDD header was incorrectly accepted." >&2
  exit 1
fi

printf 'FFDD\001x' > "$TEST_ROOT/incomplete-save"
if BUNDLED_DISK_OUTPUT_DIR="$TEST_ROOT/incomplete-save-output" \
  "$(dirname "$0")/prepare_bundled_save.sh" "$TEST_ROOT/incomplete-save" 2>/dev/null; then
  echo "Incomplete FFDD record was incorrectly accepted." >&2
  exit 1
fi

if BUNDLED_DISK_OUTPUT_DIR="$TEST_ROOT/invalid-output" \
  "$(dirname "$0")/prepare_bundled_disk.sh" "$RAW_SOURCE" vhd 2>/dev/null; then
  echo "Raw image was incorrectly accepted as VHD." >&2
  exit 1
fi

echo "PASS: bundled raw IMG, VHD and FFDD save preparation"
