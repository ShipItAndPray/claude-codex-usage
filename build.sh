#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
COMMON_BINARY="$BUILD_DIR/UsageWatchBinary"
ASSETS_DIR="$ROOT/Assets"

mkdir -p "$BUILD_DIR"

qlmanage -t -s 64 -o "$ASSETS_DIR" "$ASSETS_DIR/openai-symbol.svg" >/dev/null 2>&1 || true
qlmanage -t -s 64 -o "$ASSETS_DIR" "$ASSETS_DIR/anthropic-favicon.ico" >/dev/null 2>&1 || true

swiftc \
  -framework AppKit \
  -framework Security \
  "$ROOT/Sources/UsageWatch/main.swift" \
  -o "$COMMON_BINARY"

create_app() {
  local executable_name="$1"
  local bundle_name="$2"
  local bundle_id="$3"
  shift 3
  local services=("$@")
  local app_dir="$BUILD_DIR/$executable_name.app"
  local macos_dir="$app_dir/Contents/MacOS"
  local resources_dir="$app_dir/Contents/Resources"
  local plist="$app_dir/Contents/Info.plist"

  rm -rf "$app_dir"
  mkdir -p "$macos_dir" "$resources_dir"

  cp "$ROOT/Info.plist" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $executable_name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $bundle_name" "$plist"
  /usr/libexec/PlistBuddy -c "Delete :UsageWatchServices" "$plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :UsageWatchServices array" "$plist"

  local index=0
  for service in "${services[@]}"; do
    /usr/libexec/PlistBuddy -c "Add :UsageWatchServices:$index string $service" "$plist"
    index=$((index + 1))
  done

  cp "$COMMON_BINARY" "$macos_dir/$executable_name"
  chmod +x "$macos_dir/$executable_name"
  cp "$ASSETS_DIR/openai-symbol.svg.png" "$resources_dir/openai.png"
  cp "$ASSETS_DIR/anthropic-favicon.ico.png" "$resources_dir/anthropic.png"
  codesign --force --deep --sign - --timestamp=none "$app_dir" >/dev/null 2>&1 || true
}

create_app "WindowWatch" "WindowWatch" "local.somepalli.windowwatch" "claude" "codex"
create_app "ClaudeWindowWatch" "ClaudeWindowWatch" "local.somepalli.claudewindowwatch" "claude"
create_app "CodexWindowWatch" "CodexWindowWatch" "local.somepalli.codexwindowwatch" "codex"

printf '%s\n' \
  "$BUILD_DIR/WindowWatch.app" \
  "$BUILD_DIR/ClaudeWindowWatch.app" \
  "$BUILD_DIR/CodexWindowWatch.app"
