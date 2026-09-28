#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
ARCH="${1:-native}"
case "$ARCH" in
  native|arm64|x86_64) ;;
  *) echo "usage: $0 [native|arm64|x86_64]" >&2; exit 2 ;;
esac
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/justrecorder-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCES=()
while IFS= read -r source; do
  SOURCES+=("$source")
done < <(find Sources/JustRecorder -name '*.swift' ! -name main.swift -print)
if [[ "$ARCH" == native ]]; then
  swiftc -swift-version 5 "${SOURCES[@]}" Tests/JustRecorderTests/*.swift -o "$TEST_DIR/regressions"
  "$TEST_DIR/regressions"
else
  swiftc -swift-version 5 -target "${ARCH}-apple-macosx13.0" "${SOURCES[@]}" Tests/JustRecorderTests/*.swift -o "$TEST_DIR/regressions"
  /usr/bin/arch "-${ARCH}" "$TEST_DIR/regressions"
fi
