#!/bin/bash
# Builds a release Ribbon.app into build/.
#   Scripts/build-app.sh            # ad-hoc signed
#   RIBBON_SIGN_IDENTITY="My Cert" Scripts/build-app.sh
# Ad-hoc builds carry a designated requirement that only names the bundle id, so the
# Accessibility permission should survive rebuilds (a default ad-hoc requirement pins the
# exact binary hash). Signing with a real certificate works too.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Universal (Apple silicon + Intel) by default; RIBBON_ARCHS="arm64" for a faster local build.
ARCH_FLAGS=()
for arch in ${RIBBON_ARCHS:-arm64 x86_64}; do ARCH_FLAGS+=(--arch "$arch"); done
"$ROOT/Scripts/swiftw" build -c release --product Ribbon "${ARCH_FLAGS[@]}" --scratch-path "$ROOT/.build-release"
BIN="$ROOT/.build-release/out/Products/Release/Ribbon"
[ -x "$BIN" ] || BIN="$(find "$ROOT/.build-release" -type f -perm -111 -name Ribbon -path "*Products*" | head -1)"
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "error: release binary not found" >&2; exit 1; }

APP="$ROOT/build/Ribbon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ribbon"
# Strip debug-map and local symbols: they embed absolute build paths (including the
# builder's home folder), which have no business in a published binary.
strip -S -x "$APP/Contents/MacOS/Ribbon"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -z "${RIBBON_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign - --identifier com.raff.ribbon \
    --requirements '=designated => identifier "com.raff.ribbon"' --timestamp=none "$APP"
else
  codesign --force --sign "$RIBBON_SIGN_IDENTITY" --identifier com.raff.ribbon --timestamp=none "$APP"
fi
codesign --verify --verbose=1 "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Ribbon"))"
