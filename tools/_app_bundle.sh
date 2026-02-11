#!/usr/bin/env bash
set -euo pipefail

validate_app_bundle() {
  local app_path="$1"
  if [[ -z "$app_path" ]]; then
    echo "validate_app_bundle: missing path" >&2
    return 2
  fi
  if [[ ! -d "$app_path" ]]; then
    echo "validate_app_bundle: app bundle not found: $app_path" >&2
    return 2
  fi
  local plist="$app_path/Contents/Info.plist"
  if [[ ! -f "$plist" ]]; then
    echo "validate_app_bundle: Info.plist missing: $plist" >&2
    return 2
  fi
  if ! /usr/bin/plutil -lint "$plist" >/dev/null 2>&1; then
    echo "validate_app_bundle: Info.plist invalid: $plist" >&2
    return 2
  fi
  local exe
  exe="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist" 2>/dev/null || true)"
  if [[ -z "$exe" ]]; then
    echo "validate_app_bundle: CFBundleExecutable missing in $plist" >&2
    return 2
  fi
  local bin="$app_path/Contents/MacOS/$exe"
  if [[ ! -x "$bin" ]]; then
    echo "validate_app_bundle: executable missing or not executable: $bin" >&2
    return 2
  fi
  return 0
}
