#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
INFO_PLIST="$ROOT/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
RELEASE_DIR="$BUILD_DIR/releases/v$VERSION"

"$ROOT/build.sh" >/dev/null

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

package_app() {
  local app_name="$1"
  local archive_path="$RELEASE_DIR/$app_name-$VERSION.zip"
  ditto -c -k --sequesterRsrc --keepParent "$BUILD_DIR/$app_name.app" "$archive_path"
  shasum -a 256 "$archive_path"
}

{
  package_app "WindowWatch"
  package_app "ClaudeWindowWatch"
  package_app "CodexWindowWatch"
} | tee "$RELEASE_DIR/checksums.txt"

printf '\nRelease assets:\n'
find "$RELEASE_DIR" -maxdepth 1 -type f | sort
