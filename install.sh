#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLICATIONS_DIR="/Applications"

build_apps() {
  "$ROOT/build.sh" >/dev/null
}

install_bundle() {
  local source_app="$1"
  local target_app="$2"
  local executable_name="$3"

  if pgrep -x "$executable_name" >/dev/null 2>&1; then
    pkill -x "$executable_name" >/dev/null 2>&1 || true
    sleep 1
  fi

  rm -rf "$target_app"
  ditto "$source_app" "$target_app"
  xattr -dr com.apple.quarantine "$target_app" >/dev/null 2>&1 || true
  open "$target_app"
}

install_selection() {
  local selection="$1"

  case "$selection" in
    combined)
      install_bundle "$ROOT/build/WindowWatch.app" "$APPLICATIONS_DIR/WindowWatch.app" "WindowWatch"
      printf 'Installed %s\n' "$APPLICATIONS_DIR/WindowWatch.app"
      ;;
    claude)
      install_bundle "$ROOT/build/ClaudeWindowWatch.app" "$APPLICATIONS_DIR/ClaudeWindowWatch.app" "ClaudeWindowWatch"
      printf 'Installed %s\n' "$APPLICATIONS_DIR/ClaudeWindowWatch.app"
      ;;
    codex)
      install_bundle "$ROOT/build/CodexWindowWatch.app" "$APPLICATIONS_DIR/CodexWindowWatch.app" "CodexWindowWatch"
      printf 'Installed %s\n' "$APPLICATIONS_DIR/CodexWindowWatch.app"
      ;;
    all)
      install_selection combined
      install_selection claude
      install_selection codex
      ;;
    *)
      printf 'Unknown install target: %s\n' "$selection" >&2
      return 1
      ;;
  esac
}

prompt_for_selection() {
  printf '\nWindowWatch installer\n\n'
  printf '1. Install WindowWatch (Claude + Codex) [default]\n'
  printf '2. Install ClaudeWindowWatch\n'
  printf '3. Install CodexWindowWatch\n'
  printf '4. Install all three\n'
  printf '\nChoose an option [1-4, default 1]: '

  local choice
  read -r choice

  case "$choice" in
    ""|1) printf 'combined' ;;
    2) printf 'claude' ;;
    3) printf 'codex' ;;
    4) printf 'all' ;;
    *)
      printf 'Invalid selection.\n' >&2
      return 1
      ;;
  esac
}

main() {
  local selection="${1:-combined}"

  if [[ "${INTERACTIVE_INSTALL:-1}" == "1" && $# -eq 0 ]]; then
    selection="$(prompt_for_selection)"
  fi

  build_apps
  install_selection "$selection"

  printf '\nDone.\n'
  printf 'If macOS warns that the app is unsigned, right-click the app in /Applications and choose Open once.\n'
}

main "${1:-}"
