#!/bin/bash
# Builds Strata.app from the SwiftPM package (no Xcode project needed) and signs it.
#   scripts/build-app.sh [--debug] [--out DIR] [--identity NAME|adhoc]
# Result: <out>/Strata.app (default: dist/Strata.app) and <out>/Strata-<version>.zip
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=release; OUT="$REPO/dist"; IDENTITY="${STRATA_SIGN_IDENTITY:-Strata Signing}"
while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIG=debug ;;
    --out) OUT="$2"; shift ;;
    --identity) IDENTITY="$2"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac; shift
done
# SwiftUI's macros (@State, @Observable…) need the SwiftUIMacros plugin, which only ships inside Xcode.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! echo "${DEVELOPER_DIR:-$(xcode-select -p)}" | grep -q "Xcode.app"; then
  echo "error: building the GUI requires Xcode (SwiftUI macros are not in the Command Line Tools)." >&2
  echo "       install Xcode, then: export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi
VERSION="$(grep -o 'version = "[^"]*"' "$REPO/Sources/StrataCore/Model/Version.swift" | cut -d'"' -f2)"
BUILD="$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 1)"
APP="$OUT/Strata.app"

echo "==> swift build ($CONFIG)"
( cd "$REPO" && swift build -c "$CONFIG" --product strata 2>&1 | grep -v "ld: warning: search path" )
BIN="$REPO/.build/$CONFIG/strata"

echo "==> assembling $APP (version $VERSION build $BUILD)"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Strata"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" "$REPO/packaging/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ ! -f "$OUT/AppIcon.icns" ]; then
  echo "==> rendering icon"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift "$REPO/scripts/make-icon.swift" "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"
fi
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$REPO/configs" "$APP/Contents/Resources/configs"
cp "$REPO/packaging/dev.farzadhayat.strata.daemon.plist" "$REPO/packaging/dev.farzadhayat.strata.agent.plist" "$APP/Contents/Resources/"
cp "$REPO/uninstall.sh" "$APP/Contents/Resources/uninstall.sh" 2>/dev/null || true

echo "==> signing"
if [ "$IDENTITY" != "adhoc" ] && security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --options runtime --timestamp=none --identifier dev.farzadhayat.strata -s "$IDENTITY" "$APP"
else
  echo "WARNING: signing identity '$IDENTITY' not found — using ad-hoc signature." >&2
  echo "         TCC permissions will need re-granting after every rebuild. Run scripts/make-signing-cert.sh to fix." >&2
  codesign --force --identifier dev.farzadhayat.strata -s - "$APP"
fi
codesign --verify --strict "$APP" && codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority|Signature" | head -3

echo "==> zipping"
( cd "$OUT" && rm -f "Strata-$VERSION.zip" && ditto -c -k --keepParent Strata.app "Strata-$VERSION.zip" )
echo "built $APP and $OUT/Strata-$VERSION.zip"
