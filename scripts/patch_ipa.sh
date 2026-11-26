#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/patch_ipa.sh <input.ipa> <LCProxyTweak.dylib> <xray_ios_arm64_dir> <insert_dylib_bin> <output.ipa> [clone_bundle_suffix] [clone_display_name]

if [[ $# -lt 5 ]]; then
  echo "Usage: $0 <input.ipa> <tweak.dylib> <xray_ios_arm64_dir> <insert_dylib_bin> <output.ipa> [clone_bundle_suffix] [clone_display_name]" >&2
  exit 1
fi

INPUT_IPA="$1"
TWEAK_DYLIB="$2"
XRAY_SLICE_DIR="$3"
INSERT_DYLIB="$4"
OUTPUT_IPA="$5"
CLONE_SUFFIX="${6:-xray}"
CLONE_DISPLAY_NAME="${7:-LiveContainer Xray}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "[patch_ipa] Extracting $INPUT_IPA..."
unzip -q "$INPUT_IPA" -d "$WORK_DIR"

APP_DIR="$(find "$WORK_DIR/Payload" -maxdepth 1 -name '*.app' -type d | awk 'NR==1{print}')"
if [[ -z "$APP_DIR" ]]; then
  echo "[patch_ipa] ERROR: No .app bundle found inside Payload/" >&2
  exit 1
fi

INFO_PLIST="$APP_DIR/Info.plist"
APP_NAME="$(basename "$APP_DIR" .app)"
MAIN_BIN="$APP_DIR/$APP_NAME"
if [[ ! -f "$MAIN_BIN" ]]; then
  MAIN_BIN="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
  MAIN_BIN="$APP_DIR/$MAIN_BIN"
fi

# ---------------------------------------------------------------------------
# Clone Bundle Identifier, Display Name & PlugIns (.appex)
# so this build installs cleanly alongside stock LiveContainer without conflicts
# ---------------------------------------------------------------------------
ORIG_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
if [[ -n "$CLONE_SUFFIX" ]]; then
  CLEAN_SUFFIX="$(echo "$CLONE_SUFFIX" | tr -cd 'A-Za-z0-9-')"
  NEW_BUNDLE_ID="${ORIG_BUNDLE_ID}.${CLEAN_SUFFIX}"
  echo "[patch_ipa] Cloning Bundle ID: $ORIG_BUNDLE_ID -> $NEW_BUNDLE_ID"
  echo "[patch_ipa] Setting Display Name: $CLONE_DISPLAY_NAME"

  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_BUNDLE_ID" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $CLONE_DISPLAY_NAME" "$INFO_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $CLONE_DISPLAY_NAME" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $CLONE_DISPLAY_NAME" "$INFO_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleName string $CLONE_DISPLAY_NAME" "$INFO_PLIST"

  # Update localized InfoPlist.strings so iOS Home Screen shows cloned display name
  while IFS= read -r lproj_plist; do
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $CLONE_DISPLAY_NAME" "$lproj_plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $CLONE_DISPLAY_NAME" "$lproj_plist" 2>/dev/null || true
  done < <(find "$APP_DIR" -maxdepth 2 -path '*.lproj/InfoPlist.strings' -type f)

  # IMPORTANT: Do NOT rename CFBundleURLSchemes[0] ("livecontainer")!
  # LiveContainer checks `LCUtils.appUrlScheme()?.lowercased() != "livecontainer"`
  # (LiveContainerSwiftUI/Utilities/Shared.swift) and switches to secondary
  # LiveContainer2 mode (`multiLCStatus = 2`) if changed, which hides the '+'
  # install button, Sources/Tweaks tabs, and Certificate Import in Settings.
  # iOS allows multiple apps with distinct CFBundleIdentifiers to share a URL scheme.
  echo "[patch_ipa] Preserving CFBundleURLSchemes ('livecontainer') to keep full primary LiveContainer mode"

  # Update all embedded PlugIns/*.appex Bundle IDs to inherit the new parent prefix
  if [[ -d "$APP_DIR/PlugIns" ]]; then
    while IFS= read -r appex_plist; do
      EXT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$appex_plist" 2>/dev/null || true)"
      if [[ "$EXT_ID" == "${ORIG_BUNDLE_ID}."* ]]; then
        EXT_TAIL="${EXT_ID#"${ORIG_BUNDLE_ID}."}"
        NEW_EXT_ID="${NEW_BUNDLE_ID}.${EXT_TAIL}"
        echo "[patch_ipa] Cloning PlugIn Bundle ID: $EXT_ID -> $NEW_EXT_ID"
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_EXT_ID" "$appex_plist"
      fi
    done < <(find "$APP_DIR/PlugIns" -maxdepth 2 -name 'Info.plist' -type f)
  fi
fi

FRAMEWORKS_DIR="$APP_DIR/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

echo "[patch_ipa] Copying LCProxyTweak.dylib into Frameworks/..."
cp -f "$TWEAK_DYLIB" "$FRAMEWORKS_DIR/LCProxyTweak.dylib"
chmod 755 "$FRAMEWORKS_DIR/LCProxyTweak.dylib"

# Auto-detect whether XrayRust slice is a dynamic framework or static archive
XRAY_FRAMEWORK_DIR="$(find "$XRAY_SLICE_DIR" -maxdepth 2 -name '*.framework' -type d | awk 'NR==1{print}' || true)"
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
echo "[patch_ipa] Injecting @executable_path/Frameworks/LCProxyTweak.dylib into main binary: $MAIN_BIN"
"$INSERT_DYLIB" --strip-codesig --inplace --all-yes "@executable_path/Frameworks/LCProxyTweak.dylib" "$MAIN_BIN"

# Inject into TweakLoader.dylib so ALL guest apps (including LiveProcess multitasking) load LCProxyTweak.dylib
TWEAK_LOADERS="$(find "$APP_DIR" -name 'TweakLoader.dylib' -type f || true)"
if [[ -n "$TWEAK_LOADERS" ]]; then
  while IFS= read -r loader; do
    LOADER_DIR="$(dirname "$loader")"
    if [[ "$LOADER_DIR" == "$FRAMEWORKS_DIR" ]]; then
      INJECT_PATH="@loader_path/LCProxyTweak.dylib"
    else
      INJECT_PATH="@rpath/LCProxyTweak.dylib"
    fi
    echo "[patch_ipa] Injecting $INJECT_PATH into guest loader: $loader"
    "$INSERT_DYLIB" --strip-codesig --inplace --all-yes "$INJECT_PATH" "$loader"
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

# Remove invalidated _CodeSignature directories from app, frameworks, and PlugIns so signer re-signs cleanly
echo "[patch_ipa] Cleaning invalidated _CodeSignature directories..."
rm -rf "$APP_DIR/_CodeSignature"
find "$FRAMEWORKS_DIR" -maxdepth 2 -name '_CodeSignature' -type d -exec rm -rf {} +
if [[ -d "$APP_DIR/PlugIns" ]]; then
  find "$APP_DIR/PlugIns" -maxdepth 2 -name '_CodeSignature' -type d -exec rm -rf {} +
fi

echo "[patch_ipa] Repacking IPA -> $OUTPUT_IPA"
ABS_OUTPUT="$(cd "$(dirname "$OUTPUT_IPA")" && pwd)/$(basename "$OUTPUT_IPA")"
rm -f "$ABS_OUTPUT"
(
  cd "$WORK_DIR"
  zip -qry "$ABS_OUTPUT" Payload
)

echo "[patch_ipa] Done: $ABS_OUTPUT ($(du -h "$ABS_OUTPUT" | awk '{print $1}'))"
