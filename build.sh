#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
COMMON_BINARY="$BUILD_DIR/ClaudeCodexUsageBinary"
ASSETS_DIR="$ROOT/Assets"

mkdir -p "$BUILD_DIR"

# Keep the build output aligned with the current app name instead of accumulating old bundle names.
find "$BUILD_DIR" -maxdepth 1 \( -name "*.app" -o -name "*Binary" \) -exec rm -rf {} +

qlmanage -t -s 64 -o "$ASSETS_DIR" "$ASSETS_DIR/openai-symbol.svg" >/dev/null 2>&1 || true
qlmanage -t -s 64 -o "$ASSETS_DIR" "$ASSETS_DIR/anthropic-favicon.ico" >/dev/null 2>&1 || true

swiftc \
  -framework AppKit \
  -framework Security \
  "$ROOT/Sources/ClaudeCodexUsage/main.swift" \
  -o "$COMMON_BINARY"

create_app() {
  local executable_name="$1"
  local app_name="$2"
  local bundle_name="$3"
  local bundle_id="$4"
  shift 4
  local services=("$@")
  local app_dir="$BUILD_DIR/$app_name.app"
  local macos_dir="$app_dir/Contents/MacOS"
  local resources_dir="$app_dir/Contents/Resources"
  local plist="$app_dir/Contents/Info.plist"

  rm -rf "$app_dir"
  mkdir -p "$macos_dir" "$resources_dir"

  cp "$ROOT/Info.plist" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $executable_name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $bundle_name" "$plist"
  /usr/libexec/PlistBuddy -c "Delete :ClaudeCodexUsageServices" "$plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :ClaudeCodexUsageServices array" "$plist"

  local index=0
  for service in "${services[@]}"; do
    /usr/libexec/PlistBuddy -c "Add :ClaudeCodexUsageServices:$index string $service" "$plist"
    index=$((index + 1))
  done

  cp "$COMMON_BINARY" "$macos_dir/$executable_name"
  chmod +x "$macos_dir/$executable_name"
  cp "$ASSETS_DIR/openai-symbol.svg.png" "$resources_dir/openai.png"
  cp "$ASSETS_DIR/anthropic-favicon.ico.png" "$resources_dir/anthropic.png"
  codesign --force --deep --sign - --timestamp=none "$app_dir" >/dev/null 2>&1 || true
}

create_app "ClaudeCodexUsage" "Claude Codex Usage" "Claude Codex Usage" "io.github.shipitandpray.claudecodexusage" "claude" "codex"
create_app "ClaudeUsage" "Claude Usage" "Claude Usage" "io.github.shipitandpray.claudeusage" "claude"
create_app "CodexUsage" "Codex Usage" "Codex Usage" "io.github.shipitandpray.codexusage" "codex"

printf '%s\n' \
  "$BUILD_DIR/Claude Codex Usage.app" \
  "$BUILD_DIR/Claude Usage.app" \
  "$BUILD_DIR/Codex Usage.app"
