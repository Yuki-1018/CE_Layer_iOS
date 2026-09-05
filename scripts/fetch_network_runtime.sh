#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="$ROOT_DIR/Vendor/UTMFrameworks"
UTM_VERSION="4.7.5"
UTM_IPA_URL="https://github.com/utmapp/UTM/releases/download/v${UTM_VERSION}/UTM.ipa"
UTM_IPA_SHA256="999d17d735af7e19db2029661c4d68fe0dcec003e3fc646899d7a569e48ec101"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/win95-network.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

IPA="$TEMP_DIR/UTM.ipa"
curl --fail --location --proto '=https' --proto-redir '=https' \
  --max-time 300 --output "$IPA" "$UTM_IPA_URL"
echo "$UTM_IPA_SHA256  $IPA" | shasum -a 256 --check

mkdir -p "$TEMP_DIR/extracted" "$DESTINATION"
for framework in slirp.0 glib-2.0.0 iconv.2 intl.8; do
  unzip -q "$IPA" "Payload/UTM.app/Frameworks/${framework}.framework/*" -d "$TEMP_DIR/extracted"
  rm -rf "$DESTINATION/${framework}.framework"
  cp -R "$TEMP_DIR/extracted/Payload/UTM.app/Frameworks/${framework}.framework" "$DESTINATION/"
done
unzip -p "$IPA" Payload/UTM.app/Settings.bundle/License.plist \
  > "$ROOT_DIR/Win95iOS/BundledContent/UTM-DEPENDENCY-LICENSES.plist"

echo "UTM ${UTM_VERSION} user-mode networking runtime is ready."
