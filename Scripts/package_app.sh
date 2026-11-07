#!/usr/bin/env bash
# Builds HerdrBar.app next to this repo: swift build -c release, an LSUIElement bundle, ad-hoc codesign.
# APP_IDENTITY="Developer ID Application: ..." signs with that identity instead.
set -euo pipefail

CONF="${1:-release}"
case "$CONF" in
  debug|release) ;;
  *) echo "ERROR: unsupported configuration: $CONF (debug or release)" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/version.env"

BUNDLE_ID="io.github.jrecos.herdrbar"
if [[ "$CONF" == "debug" ]]; then
  BUNDLE_ID="${BUNDLE_ID}.debug"
fi

swift build -c "$CONF"
BIN_DIR="$(swift build -c "$CONF" --show-bin-path)"
BINARY="$BIN_DIR/HerdrBar"
if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: missing built binary at $BINARY" >&2
  exit 1
fi

APP="$ROOT/HerdrBar.app"
STAGE="$ROOT/.build/package/HerdrBar.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BINARY" "$STAGE/Contents/MacOS/HerdrBar"
chmod +x "$STAGE/Contents/MacOS/HerdrBar"
cp "$ROOT/LICENSE" "$STAGE/Contents/Resources/LICENSE"
if [[ "$CONF" == "release" ]]; then
  xcrun strip -x "$STAGE/Contents/MacOS/HerdrBar"
fi
if [[ -f "$ROOT/Icon.icns" ]]; then
  cp "$ROOT/Icon.icns" "$STAGE/Contents/Resources/Icon.icns"
fi

GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>HerdrBar</string>
    <key>CFBundleDisplayName</key><string>HerdrBar</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>HerdrBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>Icon</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Jrecos. MIT License.</string>
    <key>HerdrBarGitCommit</key><string>${GIT_COMMIT}</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

xattr -cr "$STAGE"
if [[ -n "${APP_IDENTITY:-}" ]]; then
  codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" "$STAGE"
else
  codesign --force --sign - "$STAGE"
fi
codesign --verify --strict --verbose=2 "$STAGE"

rm -rf "$APP"
mv "$STAGE" "$APP"
echo "Created $APP"
