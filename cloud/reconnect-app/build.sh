#!/usr/bin/env bash
# Builds the OpenMessage Reconnect app for clients' computers:
#   <out>/om-reconnect-mac.zip       OpenMessage Reconnect.app (Apple silicon + Intel)
#   <out>/om-reconnect-windows.exe   (64-bit, no console window)
#
#   cloud/reconnect-app/build.sh <out-dir> [version]
#
# On a Mac it makes one universal binary with lipo and signs the app ad hoc
# (codesign -s -). Ad hoc isn't Developer ID: the first open on a client's
# Mac needs right-click > Open (the Reconnect page says so). With
# DEVELOPER_ID="Developer ID Application: …" set, it signs with that instead;
# notarizing is up to you. Release assets: cloud/vm/release-vm.sh calls this.
set -euo pipefail
OUT=${1:?usage: build.sh <out-dir> [version]}
VERSION=${2:-dev}
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$ROOT"
mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
LD="-s -w"
build() { GOWORK=off CGO_ENABLED=0 GOOS=$1 GOARCH=$2 go build -trimpath -ldflags "$LD ${3:-}" -o "$4" ./cloud/reconnect-app; }

build windows amd64 "-H=windowsgui" "$OUT/om-reconnect-windows.exe"

build darwin arm64 "" "$WORK/arm64"
build darwin amd64 "" "$WORK/amd64"
APP="$WORK/OpenMessage Reconnect.app"
mkdir -p "$APP/Contents/MacOS"
if command -v lipo >/dev/null; then
  lipo -create -output "$APP/Contents/MacOS/om-reconnect" "$WORK/arm64" "$WORK/amd64"
else
  cp "$WORK/arm64" "$APP/Contents/MacOS/om-reconnect"   # Apple silicon only
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>OpenMessage Reconnect</string>
  <key>CFBundleDisplayName</key><string>OpenMessage Reconnect</string>
  <key>CFBundleIdentifier</key><string>com.openmessage.reconnect</string>
  <key>CFBundleExecutable</key><string>om-reconnect</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION#v}</string>
  <key>CFBundleVersion</key><string>${VERSION#v}</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
if command -v codesign >/dev/null; then
  codesign --force --deep -s "${DEVELOPER_ID:--}" "$APP" >/dev/null 2>&1 || echo "codesign failed; app is unsigned" >&2
fi
(cd "$WORK" && rm -f "$OUT/om-reconnect-mac.zip" && \
  if command -v ditto >/dev/null; then ditto -c -k --keepParent "OpenMessage Reconnect.app" "$OUT/om-reconnect-mac.zip";
  else zip -qry "$OUT/om-reconnect-mac.zip" "OpenMessage Reconnect.app"; fi)
echo "Built $OUT/om-reconnect-mac.zip and $OUT/om-reconnect-windows.exe"
