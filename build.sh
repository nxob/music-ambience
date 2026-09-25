#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="Afterglow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

echo "Compiling..."
swiftc -O *.swift -o "$APP/Contents/MacOS/Afterglow" -framework Cocoa -framework ScreenCaptureKit -framework CoreMedia

echo "Making icon..."
if "$APP/Contents/MacOS/Afterglow" --render-icon icon_1024.png && [ -f icon_1024.png ]; then
  ICONSET="Afterglow.iconset"
  rm -rf "$ICONSET"; mkdir "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Afterglow.icns"
  rm -rf "$ICONSET" icon_1024.png
else
  echo "(icon step skipped, app still works)"
fi

codesign --force --deep -s - "$APP"
echo "Done. Drag $APP into /Applications and open it."
