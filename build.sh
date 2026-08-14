#!/bin/sh
set -e
cd "$(dirname "$0")"

APP=Brush.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# 애플 실리콘 / 인텔 둘 다에서 돌게 하나로 합친다 — 받는 사람 기기를 물어볼 수 없으니
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc -O -target arm64-apple-macos13  Brush.swift -o "$TMP/arm64"
swiftc -O -target x86_64-apple-macos13 Brush.swift -o "$TMP/x86_64"
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/Brush"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Brush</string>
  <key>CFBundleExecutable</key>      <string>Brush</string>
  <key>CFBundleIdentifier</key>      <string>local.brush</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>LSUIElement</key>             <true/>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

"$APP/Contents/MacOS/Brush" --selftest

# 배포용 zip은 릴리스에 올릴 때만 필요 — ./build.sh --zip
if [ "$1" = "--zip" ]; then
  rm -f Brush.zip
  ditto -c -k --keepParent "$APP" Brush.zip
  echo "배포용 압축: $(pwd)/Brush.zip"
fi

echo "빌드 완료: $(pwd)/$APP   ($(lipo -archs "$APP/Contents/MacOS/Brush"))   (열기: open $APP)"
