#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT_DIR/Vendor/dosbox-pure"
TEST_DIR="$(mktemp -d /tmp/win95-storage-test.XXXXXX)"
echo "Synthetic fixtures and recovery backups: $TEST_DIR"
make -C "$CORE_DIR" -j4 STATIC_LINKING=1 OUTNAME=libdosbox_pure-test.a MAKE_CPUFLAGS=-DDISABLE_DYNAREC=1
c++ -std=c++11 -DNDEBUG -DDISABLE_DYNAREC=1 -D__LIBRETRO__ \
    -I"$CORE_DIR/include" -I"$CORE_DIR/libretro-common/include" \
    "$ROOT_DIR/tests/core_storage.cpp" "$CORE_DIR/libdosbox_pure-test.a" -pthread -o "$TEST_DIR/core_storage"
"$TEST_DIR/core_storage" "$TEST_DIR"
