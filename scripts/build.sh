#!/bin/bash
# Builds AgyComputerUse.app (the native Computer Use service + MCP client) inside the plugin folder.
#   AGY_CU_SIGN_IDENTITY="Apple Development: ..."  sign with a stable identity so macOS keeps the
#   Accessibility / Screen Recording grants across rebuilds (default: ad-hoc signing).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src"
APP="$ROOT/AgyComputerUse.app"
STAGE="$ROOT/.AgyComputerUse.app.build"

echo "Building agy-cu (release)…"
swift build -c release --package-path "$SRC"
BIN_DIR="$(swift build -c release --package-path "$SRC" --show-bin-path)"
[ -x "$BIN_DIR/agy-cu" ] || { echo "build failed"; exit 1; }

# Stop a running service before replacing its bundle.
if [ -x "$APP/Contents/MacOS/agy-cu" ]; then
  "$APP/Contents/MacOS/agy-cu" stop >/dev/null 2>&1 || true
  sleep 0.5
fi

rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN_DIR/agy-cu" "$STAGE/Contents/MacOS/agy-cu"
cp "$SRC/Info.plist" "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# App icon from the plugin logo, when the tools are available.
if [ -f "$ROOT/assets/logo.png" ] && command -v iconutil >/dev/null; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/assets/logo.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ROOT/assets/logo.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns" || true
fi

# Prefer a local "AgyComputerUse Local" code-signing certificate when one exists: a stable identity keeps
# macOS privacy grants valid across rebuilds. Fall back to ad-hoc signing.
if [ -z "${AGY_CU_SIGN_IDENTITY:-}" ]; then
  AGY_CU_SIGN_IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"AgyComputerUse Local"/ {print $2; exit}')"
fi
IDENTITY="${AGY_CU_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier dev.agy.computer-use --options runtime "$STAGE" >/dev/null 2>&1 \
  || codesign --force --sign "$IDENTITY" --identifier dev.agy.computer-use "$STAGE"

rm -rf "$APP"
mv "$STAGE" "$APP"
echo "Built $APP (signed: $IDENTITY)"
