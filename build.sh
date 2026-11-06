#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="JustRecorder"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

INSTALL=0
MAKE_DMG=0
UNIVERSAL=0
for arg in "$@"; do
  case "${arg}" in
    --install) INSTALL=1 ;;
    --dmg) MAKE_DMG=1; UNIVERSAL=1 ;;
    --universal) UNIVERSAL=1 ;;
    -h|--help)
      echo "usage: $0 [--install] [--universal] [--dmg]"
      echo "  --install   copy the built app to /Applications and launch it"
      echo "  --universal build for Intel and Apple silicon"
      echo "  --dmg       universal build, packaged as build/JustRecorder-<version>.dmg"
      exit 0
      ;;
    *)
      echo "error: unknown argument: ${arg} (try --help)" >&2
      exit 2
      ;;
  esac
done

if ! command -v swift >/dev/null 2>&1; then
  echo "error: the Swift toolchain was not found. Install the Xcode Command Line Tools:" >&2
  echo "         xcode-select --install" >&2
  exit 1
fi

OPT_FLAGS=(-Xswiftc -Osize -Xlinker -dead_strip -Xlinker -dead_strip_dylibs)

BUILD_LOG="$(mktemp -t justrecorder-build)"
DMG_MOUNT=""
cleanup() {
  rm -f "${BUILD_LOG}"
  if [[ -n "${DMG_MOUNT}" ]]; then
    hdiutil detach "${DMG_MOUNT}" -quiet >/dev/null 2>&1 \
      || hdiutil detach "${DMG_MOUNT}" -force -quiet >/dev/null 2>&1 || true
    rmdir "${DMG_MOUNT}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "${UNIVERSAL}" -eq 1 ]]; then
  echo "==> Building a universal binary (release)…"
else
  echo "==> Building for this Mac (release)…"
fi

run_build() {
  if [[ "${UNIVERSAL}" -eq 1 ]]; then
    swift build --scratch-path .build/universal-arm64 -c release --arch arm64 "${OPT_FLAGS[@]}" >"${BUILD_LOG}" 2>&1 || return $?
    swift build --scratch-path .build/universal-x86_64 -c release --arch x86_64 "${OPT_FLAGS[@]}" >>"${BUILD_LOG}" 2>&1
  else
    swift build -c release "${OPT_FLAGS[@]}" >"${BUILD_LOG}" 2>&1
  fi
}

BUILD_OK=1
run_build || BUILD_OK=0

if [[ "${BUILD_OK}" -eq 0 ]] && grep -qE 'option.*dead_strip_dylibs' "${BUILD_LOG}"; then
  echo "==> This linker does not accept -dead_strip_dylibs; building without it…" >&2
  OPT_FLAGS=(-Xswiftc -Osize -Xlinker -dead_strip)
  BUILD_OK=1
  run_build || BUILD_OK=0
fi

if [[ "${BUILD_OK}" -eq 0 ]]; then
  cat "${BUILD_LOG}" >&2
  exit 1
fi
cat "${BUILD_LOG}"

if [[ "${UNIVERSAL}" -eq 1 ]]; then
  ARM_BIN="$(swift build --scratch-path .build/universal-arm64 -c release --arch arm64 --show-bin-path)/${APP_NAME}"
  INTEL_BIN="$(swift build --scratch-path .build/universal-x86_64 -c release --arch x86_64 --show-bin-path)/${APP_NAME}"
  mkdir -p "${BUILD_DIR}/universal"
  EXECUTABLE="${BUILD_DIR}/universal/${APP_NAME}"
  lipo -create "${ARM_BIN}" "${INTEL_BIN}" -output "${EXECUTABLE}"
else
  BIN_PATH="$(swift build -c release --show-bin-path)"
  EXECUTABLE="${BIN_PATH}/${APP_NAME}"
fi

if [[ ! -f "${EXECUTABLE}" ]]; then
  echo "error: built executable not found at ${EXECUTABLE}" >&2
  exit 1
fi

if [[ "${UNIVERSAL}" -eq 1 ]]; then
  lipo "${EXECUTABLE}" -verify_arch arm64
  lipo "${EXECUTABLE}" -verify_arch x86_64
fi

echo "==> Assembling ${APP_BUNDLE}…"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"
cp "${EXECUTABLE}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

if [[ -d Resources/AppIcon.iconset ]] && command -v iconutil >/dev/null 2>&1; then
  if ! iconutil -c icns Resources/AppIcon.iconset -o "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"; then
    echo "warning: iconutil failed; JustRecorder.app will use the generic app icon." >&2
    rm -f "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
  fi
fi

BINARY="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
binary_bytes() { wc -c < "$1" | tr -d ' '; }

BYTES_BEFORE="$(binary_bytes "${BINARY}")"
if command -v strip >/dev/null 2>&1; then
  strip -S -x "${BINARY}" 2>/dev/null \
    || echo "warning: strip failed; shipping the unstripped binary." >&2
fi
BYTES_AFTER="$(binary_bytes "${BINARY}")"

if [[ "${BYTES_AFTER}" -ge "${BYTES_BEFORE}" ]]; then
  echo "warning: stripping removed nothing (${BYTES_BEFORE} bytes before and after)." >&2
fi
echo "==> Executable: $((BYTES_AFTER / 1024)) KB stripped, from $((BYTES_BEFORE / 1024)) KB (-Osize, dead-stripped)"

SIGN_IDENTITY="${JUSTRECORDER_SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "==> Signing (ad-hoc; macOS may require renewed permission after rebuilding)…"
  codesign --force --sign - "${APP_BUNDLE}"
else
  echo "==> Signing with configured identity…"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "${APP_BUNDLE}"
fi
codesign --verify --strict "${APP_BUNDLE}"

echo "==> Done: ${APP_BUNDLE} ($(du -sh "${APP_BUNDLE}" | cut -f1))"

if [[ "${INSTALL}" -eq 1 ]]; then
  DESTINATION="/Applications/${APP_NAME}.app"
  echo "==> Installing to ${DESTINATION}…"
  if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
    osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
    for attempt in {1..10}; do
      if ! pgrep -x "${APP_NAME}" >/dev/null 2>&1; then break; fi
      sleep 1
    done
    if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
      echo "error: JustRecorder is still running. Quit it before installing; the existing app is unchanged." >&2
      exit 1
    fi
  fi
  INSTALL_STAGE="$(mktemp -d "/Applications/.justrecorder-install.XXXXXX")"
  if ! cp -R "${APP_BUNDLE}" "${INSTALL_STAGE}/${APP_NAME}.app"; then
    rm -rf "${INSTALL_STAGE}"
    echo "error: could not stage the installation; the existing app is unchanged." >&2
    exit 1
  fi
  if [[ -e "${DESTINATION}" ]]; then
    if ! mv "${DESTINATION}" "${INSTALL_STAGE}/previous.app"; then
      rm -rf "${INSTALL_STAGE}"
      echo "error: could not move the existing app; installation cancelled." >&2
      exit 1
    fi
  fi
  if ! mv "${INSTALL_STAGE}/${APP_NAME}.app" "${DESTINATION}"; then
    if [[ -e "${INSTALL_STAGE}/previous.app" ]]; then
      mv "${INSTALL_STAGE}/previous.app" "${DESTINATION}" || {
        echo "error: restore the previous app from ${INSTALL_STAGE}/previous.app" >&2
        exit 1
      }
    fi
    rm -rf "${INSTALL_STAGE}"
    echo "error: installation failed; the previous app was restored." >&2
    exit 1
  fi
  rm -rf "${INSTALL_STAGE}"
  open "${DESTINATION}"
  echo "==> JustRecorder is running — look for the waveform icon in your menu bar."
  echo "    macOS will ask for “Screen & System Audio Recording” the first time you record."
fi

if [[ "${MAKE_DMG}" -eq 1 ]]; then
  if ! command -v hdiutil >/dev/null 2>&1; then
    echo "error: hdiutil not found — a .dmg can only be built on macOS." >&2
    exit 1
  fi

  APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${APP_BUNDLE}/Contents/Info.plist")"
  DMG_PATH="${BUILD_DIR}/${APP_NAME}-${APP_VERSION}.dmg"
  VOLUME_NAME="${APP_NAME} ${APP_VERSION}"
  STAGE_DIR="${BUILD_DIR}/dmg-staging"
  RW_DMG="${BUILD_DIR}/.${APP_NAME}-${APP_VERSION}-rw.dmg"

  echo "==> Packaging ${DMG_PATH}…"
  rm -rf "${STAGE_DIR}"
  mkdir -p "${STAGE_DIR}"
  cp -R "${APP_BUNDLE}" "${STAGE_DIR}/${APP_NAME}.app"
  ln -s /Applications "${STAGE_DIR}/Applications"

  if [[ -f "${APP_BUNDLE}/Contents/Resources/AppIcon.icns" ]]; then
    cp "${APP_BUNDLE}/Contents/Resources/AppIcon.icns" "${STAGE_DIR}/.VolumeIcon.icns"
  fi

  rm -f "${DMG_PATH}" "${RW_DMG}"
  hdiutil create -quiet \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGE_DIR}" \
    -fs HFS+ \
    -format UDRW -ov \
    "${RW_DMG}"
  rm -rf "${STAGE_DIR}"

  if [[ -f "${APP_BUNDLE}/Contents/Resources/AppIcon.icns" ]] && command -v SetFile >/dev/null 2>&1; then
    DMG_MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/justrecorder-dmg.XXXXXX")"
    if hdiutil attach "${RW_DMG}" -mountpoint "${DMG_MOUNT}" -nobrowse -noverify -quiet >/dev/null 2>&1; then
      SetFile -a C "${DMG_MOUNT}" >/dev/null 2>&1 || true
      hdiutil detach "${DMG_MOUNT}" -quiet >/dev/null 2>&1 \
        || hdiutil detach "${DMG_MOUNT}" -force -quiet >/dev/null 2>&1 || true
    fi
    rmdir "${DMG_MOUNT}" >/dev/null 2>&1 || true
    DMG_MOUNT=""
  fi

  hdiutil convert -quiet "${RW_DMG}" -format UDZO -imagekey zlib-level=9 -o "${DMG_PATH}"
  rm -f "${RW_DMG}"

  if ! hdiutil verify -quiet "${DMG_PATH}" >/dev/null 2>&1; then
    echo "error: ${DMG_PATH} did not pass hdiutil verify." >&2
    exit 1
  fi

  echo "==> Done: ${DMG_PATH} ($(du -h "${DMG_PATH}" | cut -f1))"
  echo "    This disk image contains an app that has not been notarized."
fi
