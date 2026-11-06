#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/version.env"
"$ROOT/Scripts/package_app.sh" release
mkdir -p "$ROOT/dist"
ARCHIVE="HerdrBar-${MARKETING_VERSION}.zip"
rm -f "$ROOT/dist/$ARCHIVE"
ditto -c -k --keepParent "$ROOT/HerdrBar.app" "$ROOT/dist/$ARCHIVE"
cd "$ROOT/dist"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
echo "Created dist/$ARCHIVE"
cat "$ARCHIVE.sha256"
