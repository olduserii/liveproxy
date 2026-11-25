import type { RepoFile } from './types';

export const ciAndDocsFiles: RepoFile[] = [
  {
    path: 'scripts/patch_ipa.sh',
    language: 'bash',
    category: 'scripts',
    executable: true,
    summary: 'Patches LiveContainer+SideStore nightly IPA with LCProxyTweak.dylib, auto-detected XrayRust static/dynamic framework, and TweakLoader injection',
    content: `#!/usr/bin/env bash
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

APP_DIR="$(find "$WORK_DIR/Payload" -maxdepth 1 -name '*.app' -type d | awk 'NR==1{print}')"
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
`,
  },
  {
    path: '.github/workflows/build.yml',
    language: 'yaml',
    category: 'ci',
    summary: 'Automated macOS GitHub Actions pipeline: downloads XrayRust.xcframework + LiveContainer+SideStore nightly, compiles arm64 tweak, patches IPA, uploads Artifact & Release',
    content: `name: Build LiveContainer+SideStore+XrayRust IPA

on:
  push:
    branches:
      - main
  workflow_dispatch:

permissions:
  contents: write

jobs:
  build-ipa:
    runs-on: macos-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Download latest XrayRust.xcframework from aimalygin/xray-rust-mobile
        id: xray
        run: |
          set -euo pipefail
          mkdir -p build/xray

          RELEASE_JSON="$(curl -fsSL -H "Accept: application/vnd.github+json" \\
            https://api.github.com/repos/aimalygin/xray-rust-mobile/releases/latest || \\
            curl -fsSL -H "Accept: application/vnd.github+json" \\
            https://api.github.com/repos/aimalygin/xray-rust-mobile/releases | jq '.[0]')"

          TAG_NAME="$(echo "$RELEASE_JSON" | jq -r '.tag_name // "latest"')"
          ASSET_URL="$(echo "$RELEASE_JSON" | jq -r '[.assets[] | select(.name | test("xcframework.*\\\\.zip$"; "i")) | .browser_download_url] | first // empty')"

          if [[ -z "$ASSET_URL" || "$ASSET_URL" == "null" ]]; then
            echo "::error::Could not locate XrayRust.xcframework zip asset in aimalygin/xray-rust-mobile releases"
            echo "$RELEASE_JSON" | jq -r '.assets[].name'
            exit 1
          fi

          echo "Downloading XrayRust ($TAG_NAME): $ASSET_URL"
          curl -fL "$ASSET_URL" -o build/xray/XrayRust.xcframework.zip
          unzip -q build/xray/XrayRust.xcframework.zip -d build/xray/extracted

          SLICE_DIR="$(find build/xray/extracted -type d -name 'ios-arm64' | awk 'NR==1{print}')"
          if [[ -z "$SLICE_DIR" ]]; then
            echo "::error::ios-arm64 slice not found inside XrayRust.xcframework"
            find build/xray/extracted -maxdepth 4
            exit 1
          fi

          echo "xray_tag=$TAG_NAME" >> "$GITHUB_OUTPUT"
          echo "slice_dir=$SLICE_DIR" >> "$GITHUB_OUTPUT"

          echo "=== Inspecting XrayRust ios-arm64 Headers ==="
          find "$SLICE_DIR" -name '*.h' -print -exec cat {} \\;

          echo "=== Inspecting XrayRust ios-arm64 Exported C ABI Symbols (nm -gU) ==="
          XRAY_BIN="$(find "$SLICE_DIR" -type f \\( -name '*.a' -o -path '*.framework/*' ! -name '*.plist' ! -name '*.h' ! -name '*.modulemap' \\) | awk 'NR==1{print}')"
          if [[ -z "$XRAY_BIN" ]]; then
            echo "::error::No binary/archive found inside $SLICE_DIR"
            exit 1
          fi
          echo "Detected XrayRust binary: $XRAY_BIN"
          file "$XRAY_BIN"
          nm -gU "$XRAY_BIN" > build/xray/symbols.txt
          grep -E ' [Tt] _[a-zA-Z]' build/xray/symbols.txt | grep -v ' __ZN' | awk 'NR<=120{print}' || true

          echo "xray_bin=$XRAY_BIN" >> "$GITHUB_OUTPUT"

      - name: Build insert_dylib from source for macOS
        run: |
          set -euo pipefail
          git clone --depth 1 https://github.com/tyilo/insert_dylib.git build/insert_dylib_src
          clang -O2 -framework Foundation \\
            build/insert_dylib_src/insert_dylib/main.c \\
            -o build/insert_dylib
          chmod +x build/insert_dylib

      - name: Compile LCProxyTweak.dylib (arm64-apple-ios15.0)
        run: |
          set -euo pipefail
          SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
          SLICE_DIR="\${{ steps.xray.outputs.slice_dir }}"
          XRAY_BIN="\${{ steps.xray.outputs.xray_bin }}"

          # Determine linking flags dynamically based on binary type (static .a vs dynamic .framework)
          BIN_TYPE="$(file "$XRAY_BIN")"
          LINK_ARGS=()
          HEADER_ARGS=("-Itweak")

          while IFS= read -r hdr_dir; do
            HEADER_ARGS+=("-I$hdr_dir")
          done < <(find "$SLICE_DIR" -type d -name 'Headers')

          if echo "$BIN_TYPE" | grep -qi "dynamically linked shared library"; then
            FW_DIR="$(dirname "$XRAY_BIN")"
            FW_NAME="$(basename "$FW_DIR" .framework)"
            echo "Linking XrayRust dynamically: -F $(dirname "$FW_DIR") -framework $FW_NAME"
            LINK_ARGS+=("-F$(dirname "$FW_DIR")" "-framework" "$FW_NAME")
          else
            echo "Linking XrayRust statically with -force_load: $XRAY_BIN"
            LINK_ARGS+=("-Wl,-force_load,$XRAY_BIN")
          fi

          # Compile fishhook.c (C99) + all Objective-C tweak sources (ARC)
          clang -arch arm64 \\
            -isysroot "$SDK_PATH" \\
            -mios-version-min=15.0 \\
            -O2 -fPIC -c \\
            tweak/fishhook.c \\
            -o build/fishhook.o

          OBJC_SOURCES=(
            tweak/LCXrayRustBridge.m
            tweak/LCProxyNode.m
            tweak/LCConfigNormalizer.m
            tweak/LCFastSelector.m
            tweak/LCWatchdog.m
            tweak/LCProxyManager.m
            tweak/LCProxyHooks.m
            tweak/LCProxyUI.m
            tweak/TweakEntry.m
          )

          clang -arch arm64 \\
            -isysroot "$SDK_PATH" \\
            -mios-version-min=15.0 \\
            -dynamiclib -O2 -fobjc-arc \\
            "\${HEADER_ARGS[@]}" \\
            build/fishhook.o \\
            "\${OBJC_SOURCES[@]}" \\
            "\${LINK_ARGS[@]}" \\
            -framework Foundation \\
            -framework UIKit \\
            -framework QuartzCore \\
            -framework CFNetwork \\
            -framework Network \\
            -framework Security \\
            -framework WebKit \\
            -lresolv -lc++ \\
            -install_name "@rpath/LCProxyTweak.dylib" \\
            -Wl,-rpath,@executable_path/Frameworks \\
            -Wl,-rpath,@loader_path/Frameworks \\
            -o build/LCProxyTweak.dylib

          echo "=== LCProxyTweak.dylib verification ==="
          file build/LCProxyTweak.dylib
          otool -L build/LCProxyTweak.dylib

      - name: Download latest LiveContainer+SideStore nightly IPA
        id: lc
        run: |
          set -euo pipefail
          mkdir -p build/lc

          RELEASES_JSON="$(curl -fsSL -H "Accept: application/vnd.github+json" \\
            "https://api.github.com/repos/LiveContainer/LiveContainer/releases?per_page=15")"

          IPA_URL="$(echo "$RELEASES_JSON" | jq -r '
            ([.[] | select(.tag_name | test("nightly"; "i"))] + .)
            | map(.assets[]? | select(.name | test("LiveContainer\\\\+SideStore.*\\\\.ipa$"; "i")) | .browser_download_url)
            | first // empty
          ')"

          LC_TAG="$(echo "$RELEASES_JSON" | jq -r '
            ([.[] | select(.tag_name | test("nightly"; "i"))] + .)
            | map(select(.assets[]?.name | test("LiveContainer\\\\+SideStore.*\\\\.ipa$"; "i")) | .tag_name)
            | first // "nightly"
          ')"

          if [[ -z "$IPA_URL" ]]; then
            echo "::error::Could not find LiveContainer+SideStore.ipa in LiveContainer/LiveContainer releases"
            exit 1
          fi

          echo "Downloading LiveContainer+SideStore ($LC_TAG): $IPA_URL"
          curl -fL "$IPA_URL" -o build/lc/LiveContainer+SideStore.ipa
          echo "lc_tag=$LC_TAG" >> "$GITHUB_OUTPUT"

      - name: Patch IPA with LCProxyTweak.dylib
        run: |
          set -euo pipefail
          chmod +x scripts/patch_ipa.sh
          ./scripts/patch_ipa.sh \\
            build/lc/LiveContainer+SideStore.ipa \\
            build/LCProxyTweak.dylib \\
            "\${{ steps.xray.outputs.slice_dir }}" \\
            build/insert_dylib \\
            build/LiveContainer+SideStore+XrayRust.ipa

      - name: Upload IPA Artifact
        uses: actions/upload-artifact@v4
        with:
          name: LiveContainer+SideStore+XrayRust
          path: build/LiveContainer+SideStore+XrayRust.ipa
          retention-days: 30

      - name: Publish GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: build-\${{ github.run_number }}
          name: LiveContainer+SideStore+XrayRust (#\${{ github.run_number }})
          body: |
            Автоматическая сборка **LiveContainer+SideStore** с внедрённым нативным прокси-твиком на базе **xray-rust**.

            - **XrayRust core release:** \`\${{ steps.xray.outputs.xray_tag }}\`
            - **LiveContainer base:** \`\${{ steps.lc.outputs.lc_tag }}\`
            - **Без VPN entitlements** — устанавливается через SideStore с бесплатным Apple ID.
          files: build/LiveContainer+SideStore+XrayRust.ipa
`,
  },
  {
    path: 'README.md',
    language: 'markdown',
    category: 'docs',
    summary: '4-step GitHub build guide and architecture overview',
    content: `# LiveContainer + SideStore + XrayRust Proxy Tweak

Нативный прокси-твик на базе сверхлёгкого ядра **xray-rust** (\`aimalygin/xray-rust-mobile\`), автоматически встраиваемый в последнюю ночную сборку \`LiveContainer+SideStore\` через GitHub Actions — **без \`NEPacketTunnelProvider\` и без VPN entitlements**.

## Быстрый старт (4 шага)

1. **Создайте новый репозиторий на GitHub** (публичный или приватный) и распакуйте в него этот архив.
2. **Залейте файлы в ветку \`main\`:**
   \`\`\`bash
   git init -b main
   git add .
   git commit -m "Initial LiveContainer+SideStore+XrayRust build"
   git remote add origin https://github.com/<ВАШ_НИК>/<ВАШ_РЕПО>.git
   git push -u origin main
   \`\`\`
3. **Дождитесь завершения workflow** во вкладке **Actions** (или нажмите *Run workflow* вручную). GitHub Actions сам скачает \`XrayRust.xcframework\` и свежий \`LiveContainer+SideStore.ipa\`, соберёт \`LCProxyTweak.dylib\` под \`arm64-apple-ios15.0\` и пропатчит IPA.
4. **Скачайте \`LiveContainer+SideStore+XrayRust.ipa\`** из раздела **Releases** (или Artifacts) и установите на iPhone через SideStore / Impactor / iloader с бесплатным Apple ID.

## Управление на iPhone
- Полупрозрачная плавающая кнопка **XR** перетаскивается в любую точку экрана и запоминает позицию.
- **Тройной тап тремя пальцами** скрывает или возвращает плавающую кнопку.
- Поддерживаются обычные подписки (Base64/URI), JSON-подписки (Xray / sing-box) и вставка одиночных JSON-ключей с автоматической конвертацией в чистый стандартный URI.
`,
  },
  {
    path: '.gitignore',
    language: 'text',
    category: 'docs',
    summary: 'Ignore temporary build outputs and macOS metadata',
    content: `build/
*.ipa
*.dylib
*.o
.DS_Store
`,
  },
];
