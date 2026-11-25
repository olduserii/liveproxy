#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/patch_ipa.sh <input.ipa> <LCProxyTweak.dylib> <xray_ios_arm64_dir> <insert_dylib_bin> <output.ipa>

if [[ $# -lt 5 ]]; then
  echo "Usage: $0 <input.ipa> <tweak.dylib> <xray_ios_arm64_dir> <insert_dylib_bin> <output.ipa>" >&2
  exit 1
fi

INPUT_IPA="$1"
TWEAK_DYLIB="$2"
XRAY_SLICE_DIR="$3"
INSERT_DYLIB="$4"
OUTPUT_IPA="$5"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "[patch_ipa] Extracting $INPUT_IPA..."
unzip -q "$INPUT_IPA" -d "$WORK_DIR"

APP_DIR="$(find "$WORK_DIR/Payload" -maxdepth 1 -name '*.app' -type d | head -n 1)"
if [[ -z "$APP_DIR" ]]; then
  echo "[patch_ipa] ERROR: No .app bundle found inside Payload/" >&2
  exit 1
fi

APP_NAME="$(basename "$APP_DIR" .app)"
MAIN_BIN="$APP_DIR/$APP_NAME"
if [[ ! -f "$MAIN_BIN" ]]; then
  MAIN_BIN="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_DIR/Info.plist")"
  MAIN_BIN="$APP_DIR/$MAIN_BIN"
fi

FRAMEWORKS_DIR="$APP_DIR/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

echo "[patch_ipa] Copying LCProxyTweak.dylib into Frameworks/..."
cp -f "$TWEAK_DYLIB" "$FRAMEWORKS_DIR/LCProxyTweak.dylib"
chmod 755 "$FRAMEWORKS_DIR/LCProxyTweak.dylib"

# Auto-detect whether XrayRust slice is a dynamic framework or static archive
XRAY_FRAMEWORK_DIR="$(find "$XRAY_SLICE_DIR" -maxdepth 2 -name '*.framework' -type d | head -n 1 || true)"
if [[ -n "$XRAY_FRAMEWORK_DIR" ]]; then
  FW_NAME="$(basename "$XRAY_FRAMEWORK_DIR" .framework)"
  FW_BIN="$XRAY_FRAMEWORK_DIR/$FW_NAME"
  if [[ -f "$FW_BIN" ]]; then
    BIN_INFO="$(file "$FW_BIN")"
    echo "[patch_ipa] Detected XrayRust framework binary type: $BIN_INFO"
    if echo "$BIN_INFO" | grep -qi "dynamically linked shared library"; then
      echo "[patch_ipa] Embedding dynamic framework $FW_NAME.framework into Payload/$APP_NAME.app/Frameworks/..."
      rm -rf "$FRAMEWORKS_DIR/$FW_NAME.framework"
      cp -R "$XRAY_FRAMEWORK_DIR" "$FRAMEWORKS_DIR/"
      rm -rf "$FRAMEWORKS_DIR/$FW_NAME.framework/_CodeSignature"
      install_name_tool -id "@rpath/$FW_NAME.framework/$FW_NAME" "$FRAMEWORKS_DIR/$FW_NAME.framework/$FW_NAME" || true
    else
      echo "[patch_ipa] XrayRust framework is static — already linked into LCProxyTweak.dylib"
    fi
  fi
else
  echo "[patch_ipa] XrayRust slice uses static library (.a) — already linked into LCProxyTweak.dylib"
fi

# Inject LC_LOAD_DYLIB into main LiveContainer binary
echo "[patch_ipa] Injecting @rpath/LCProxyTweak.dylib into main binary: $MAIN_BIN"
"$INSERT_DYLIB" --strip-codesig --inplace --all-yes "@rpath/LCProxyTweak.dylib" "$MAIN_BIN"

# Inject into TweakLoader.dylib (and any LiveContainer2 helper) so ALL guest apps load LCProxyTweak.dylib
TWEAK_LOADERS="$(find "$APP_DIR" -name 'TweakLoader.dylib' -type f || true)"
if [[ -n "$TWEAK_LOADERS" ]]; then
  while IFS= read -r loader; do
    echo "[patch_ipa] Injecting @rpath/LCProxyTweak.dylib into guest loader: $loader"
    "$INSERT_DYLIB" --strip-codesig --inplace --all-yes "@rpath/LCProxyTweak.dylib" "$loader"
    echo "[patch_ipa] otool -L $loader:"
    otool -L "$loader"
  done <<< "$TWEAK_LOADERS"
else
  echo "[patch_ipa] Note: TweakLoader.dylib not found separately; LiveContainer main binary injection active."
fi

# Also mirror tweak into Embedded Tweaks folder if LiveContainer uses one for guest injection
if [[ -d "$APP_DIR/Tweaks" ]]; then
  cp -f "$TWEAK_DYLIB" "$APP_DIR/Tweaks/LCProxyTweak.dylib"
fi

echo "[patch_ipa] Verifying load commands with otool -L:"
otool -L "$MAIN_BIN"
otool -L "$FRAMEWORKS_DIR/LCProxyTweak.dylib"

# Remove invalidated _CodeSignature directories from modified app & frameworks so SideStore re-signs cleanly
echo "[patch_ipa] Cleaning invalidated _CodeSignature directories..."
rm -rf "$APP_DIR/_CodeSignature"
find "$FRAMEWORKS_DIR" -maxdepth 2 -name '_CodeSignature' -type d -exec rm -rf {} +

echo "[patch_ipa] Repacking IPA -> $OUTPUT_IPA"
ABS_OUTPUT="$(cd "$(dirname "$OUTPUT_IPA")" && pwd)/$(basename "$OUTPUT_IPA")"
rm -f "$ABS_OUTPUT"
(
  cd "$WORK_DIR"
  zip -qry "$ABS_OUTPUT" Payload
)

echo "[patch_ipa] Done: $ABS_OUTPUT ($(du -h "$ABS_OUTPUT" | awk '{print $1}'))"
