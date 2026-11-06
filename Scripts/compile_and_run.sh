#!/usr/bin/env bash
# Dev loop: quit running copies, build, package, relaunch, and confirm the app started.
# --test runs swift test first. --debug packages the debug configuration.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/HerdrBar.app"
CONF=release
RUN_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --test|-t) RUN_TESTS=1 ;;
    --debug) CONF=debug ;;
    --help|-h) echo "Usage: $(basename "$0") [--test] [--debug]"; exit 0 ;;
    *) echo "ERROR: unknown argument: $arg" >&2; exit 1 ;;
  esac
done

cd "$ROOT"
if [[ "$RUN_TESTS" == "1" ]]; then
  swift test
fi

echo "==> quitting running HerdrBar instances"
pkill -x HerdrBar 2>/dev/null || true
for _ in {1..20}; do
  pgrep -x HerdrBar >/dev/null || break
  sleep 0.2
done
pkill -9 -x HerdrBar 2>/dev/null || true

"$ROOT/Scripts/package_app.sh" "$CONF"

echo "==> launching $APP"
open -n "$APP"
for _ in {1..15}; do
  if pgrep -x HerdrBar >/dev/null; then
    echo "OK: HerdrBar is running."
    exit 0
  fi
  sleep 0.4
done
echo "ERROR: HerdrBar exited right after launch; check Console.app." >&2
exit 1
