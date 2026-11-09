#!/usr/bin/env bash
# Package one verified architecture as a drag-to-Applications disk image.
set -euo pipefail
[[ $# -eq 4 ]] || { echo 'usage: package-macos.sh APP VERSION arm64|x64 OUTPUT_DIR' >&2; exit 2; }
APP=$1
VERSION=$2
LABEL=$3
OUTPUT=$4
case "$LABEL" in
  arm64) ARCH=arm64 ;;
  x64) ARCH=x86_64 ;;
  *) echo 'architecture must be arm64 or x64' >&2; exit 2 ;;
esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo 'invalid version' >&2; exit 2; }
NAME=$(basename "$APP" .app)
[[ -d "$APP/Contents/MacOS" ]] || { echo "missing app: $APP" >&2; exit 1; }
ACTUAL=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$ACTUAL" == "${VERSION%%-*}" ]] || { echo "app version $ACTUAL differs from $VERSION" >&2; exit 1; }
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/package-macos.XXXXXX")
MOUNT="$STAGE/mount"
cleanup() {
  hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rm -rf "$STAGE"
}
trap cleanup EXIT
mkdir "$STAGE/image" "$MOUNT"
COPY="$STAGE/image/$NAME.app"
ditto "$APP" "$COPY"
# Swift release builds can produce both slices once. Remove the unused slice
# from every Mach-O file before signing, including any embedded libraries.
while IFS= read -r -d '' BINARY; do
  if file -b "$BINARY" | grep -q 'Mach-O'; then
    lipo "$BINARY" -verify_arch "$ARCH"
    if [[ $(lipo -archs "$BINARY") != "$ARCH" ]]; then
      lipo "$BINARY" -thin "$ARCH" -output "$BINARY.thin"
      chmod "$(stat -f '%Lp' "$BINARY")" "$BINARY.thin"
      mv "$BINARY.thin" "$BINARY"
    fi
    [[ $(lipo -archs "$BINARY") == "$ARCH" ]]
  fi
done < <(find "$COPY" -type f -print0)
xattr -cr "$COPY"
codesign --force --deep --sign - "$COPY"
codesign --verify --deep --strict "$COPY"
ln -s /Applications "$STAGE/image/Applications"
DMG="$NAME-$VERSION-macOS-$LABEL.dmg"
hdiutil create -quiet -ov -fs HFS+ -format UDZO -imagekey zlib-level=9 \
  -volname "$NAME $VERSION" -srcfolder "$STAGE/image" "$STAGE/$DMG"
hdiutil verify -quiet "$STAGE/$DMG"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$STAGE/$DMG"
codesign --verify --deep --strict "$MOUNT/$NAME.app"
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$MOUNT/$NAME.app/Contents/Info.plist")
[[ $(lipo -archs "$MOUNT/$NAME.app/Contents/MacOS/$EXECUTABLE") == "$ARCH" ]]
[[ -L "$MOUNT/Applications" ]]
hdiutil detach -quiet "$MOUNT"
mv "$STAGE/$DMG" "$OUTPUT/$DMG"
echo "$OUTPUT/$DMG"
