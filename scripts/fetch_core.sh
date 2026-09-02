#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT_DIR/Vendor/dosbox-pure"
CORE_COMMIT="7f6e8fb7385fa446d1444d671063268520bf9b54"

if [[ -d "$CORE_DIR/.git" ]]; then
  actual="$(git -C "$CORE_DIR" rev-parse HEAD)"
  if [[ "$actual" != "$CORE_COMMIT" ]]; then
    echo "Vendor/dosbox-pure is at $actual; expected $CORE_COMMIT" >&2
    exit 1
  fi
else
  mkdir -p "$ROOT_DIR/Vendor"
  git clone https://github.com/schellingb/dosbox-pure.git "$CORE_DIR"
  git -C "$CORE_DIR" checkout --detach "$CORE_COMMIT"
fi

if ! git -C "$CORE_DIR" apply --check "$ROOT_DIR/patches/dosbox-pure-ios-fixed-disk.patch" 2>/dev/null; then
  if git -C "$CORE_DIR" diff --quiet; then
    echo "The DOSBox Pure patch cannot be applied cleanly." >&2
    exit 1
  fi
else
  git -C "$CORE_DIR" apply "$ROOT_DIR/patches/dosbox-pure-ios-fixed-disk.patch"
fi

echo "DOSBox Pure $CORE_COMMIT is ready."

