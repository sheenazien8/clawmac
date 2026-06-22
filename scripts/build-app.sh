#!/usr/bin/env bash
set -euo pipefail

# Build Clawmac.app from a SwiftPM executable.
#
# Usage:
#   scripts/build-app.sh                       # ad-hoc signed .app + .dmg
#   scripts/build-app.sh --sign "Developer ID Application: Name (TEAMID)"
#   scripts/build-app.sh --no-dmg              # skip dmg creation
#   scripts/build-app.sh --version 1.0.0       # override marketing version
#   scripts/build-app.sh --build-number 42     # override build number
#
# Output:
#   .build/Clawmac.app
#   .build/Clawmac-<version>.dmg  (unless --no-dmg)
#   .build/Clawmac-<version>.zip  (unless --no-dmg)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
APP="$BUILD_DIR/Clawmac.app"
PLIST_TEMPLATE="$ROOT/Info.plist"
ENTITLEMENTS="$ROOT/Clawmac.entitlements"
ICON="$ROOT/Assets/AppIcon.icns"

SIGN_IDENTITY="-"
CREATE_DMG=1
MARKETING_VERSION=""
BUILD_NUMBER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign)        SIGN_IDENTITY="$2"; shift 2 ;;
    --no-dmg)      CREATE_DMG=0; shift ;;
    --version)     MARKETING_VERSION="$2"; shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,16p' "$0"; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$MARKETING_VERSION" ]]; then
  MARKETING_VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
  if [[ -z "$MARKETING_VERSION" ]]; then
    MARKETING_VERSION="0.1.0"
  fi
fi

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
fi

echo "→ Building Clawmac v$MARKETING_VERSION (build $BUILD_NUMBER)"
echo "→ Sign identity: $SIGN_IDENTITY"

command -v swift >/dev/null || { echo "swift not found" >&2; exit 1; }
command -v codesign >/dev/null || { echo "codesign not found (run on macOS)" >&2; exit 1; }
[[ -f "$ICON" ]] || { echo "missing $ICON — run scripts/make-icon.sh" >&2; exit 1; }

echo "→ swift build -c release"
( cd "$ROOT" && swift build -c release )

EXECUTABLE_SRC="$BUILD_DIR/release/Clawmac"
[[ -x "$EXECUTABLE_SRC" ]] || { echo "build did not produce $EXECUTABLE_SRC" >&2; exit 1; }

echo "→ Staging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXECUTABLE_SRC" "$APP/Contents/MacOS/Clawmac"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

INFO_OUT="$APP/Contents/Info.plist"
sed \
  -e "s|__MARKETING_VERSION__|$MARKETING_VERSION|g" \
  -e "s|__BUILD_NUMBER__|$BUILD_NUMBER|g" \
  "$PLIST_TEMPLATE" > "$INFO_OUT"

# ad-hoc signatures don't support --entitlements; only attach when using a real identity
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  echo "→ codesign (with entitlements)"
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP"
else
  echo "→ codesign (ad-hoc, no entitlements)"
  codesign \
    --force \
    --deep \
    --sign "-" \
    "$APP"
fi

codesign --verify --strict --verbose=2 "$APP"

if [[ $CREATE_DMG -eq 1 ]]; then
  echo "→ Creating DMG"
  STAGING="$BUILD_DIR/dmg-staging"
  rm -rf "$STAGING"
  mkdir -p "$STAGING"
  cp -R "$APP" "$STAGING/"

  DMG="$BUILD_DIR/Clawmac-${MARKETING_VERSION}.dmg"
  ZIP="$BUILD_DIR/Clawmac-${MARKETING_VERSION}.zip"

  if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
      --volname "Clawmac" \
      --window-pos 200 120 \
      --window-size 600 400 \
      --icon-size 100 \
      --icon "Clawmac.app" 175 190 \
      --app-drop-link 425 190 \
      "$DMG" "$STAGING" >/dev/null
  else
    hdiutil create -volname "Clawmac" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
  fi

  # zip for users who prefer it (also used by GitHub Release as alt asset)
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

  echo "→ wrote $DMG"
  echo "→ wrote $ZIP"
fi

echo "✓ done"
echo "  app : $APP"
echo "  ver : $MARKETING_VERSION ($BUILD_NUMBER)"
