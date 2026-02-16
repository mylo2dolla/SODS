#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: tools/verify-app-icons.sh --target devstation|scanner-ios|all
USAGE
}

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

pass() {
  echo "[PASS] $*"
}

require_file() {
  local path="$1"
  local description="$2"
  [[ -f "$path" ]] || fail "$description missing at $path"
}

require_dir() {
  local path="$1"
  local description="$2"
  [[ -d "$path" ]] || fail "$description missing at $path"
}

require_text() {
  local file="$1"
  local needle="$2"
  local description="$3"
  if ! grep -Fq "$needle" "$file"; then
    fail "$description not found in $file (expected: $needle)"
  fi
}

png_dims() {
  local file="$1"
  /usr/bin/sips -g pixelWidth -g pixelHeight "$file" 2>/dev/null | awk '
    /pixelWidth:/ { w = $2 }
    /pixelHeight:/ { h = $2 }
    END {
      if (w == "" || h == "") {
        exit 1
      }
      printf "%sx%s", w, h
    }
  '
}

expect_dims() {
  local file="$1"
  local expected="$2"
  local context="$3"
  local actual
  actual="$(png_dims "$file")" || fail "Unable to read pixel dimensions for $file"
  [[ "$actual" == "$expected" ]] || fail "$context has wrong size for $(basename "$file"): expected $expected, got $actual"
}

expected_entries_from_contents() {
  local json_path="$1"
  local mode="$2"
  /usr/bin/python3 - "$json_path" "$mode" <<'PY'
import json
import sys

json_path = sys.argv[1]
mode = sys.argv[2]

with open(json_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
images = data.get("images")
if not isinstance(images, list):
    raise SystemExit("Contents.json missing images[]")

if mode == "devstation":
    required = {
        ("mac", "16x16", "1x"),
        ("mac", "16x16", "2x"),
        ("mac", "32x32", "1x"),
        ("mac", "32x32", "2x"),
        ("mac", "128x128", "1x"),
        ("mac", "128x128", "2x"),
        ("mac", "256x256", "1x"),
        ("mac", "256x256", "2x"),
        ("mac", "512x512", "1x"),
        ("mac", "512x512", "2x"),
    }
elif mode == "scanner-ios":
    required = {
        ("iphone", "20x20", "2x"),
        ("iphone", "20x20", "3x"),
        ("iphone", "29x29", "2x"),
        ("iphone", "29x29", "3x"),
        ("iphone", "40x40", "2x"),
        ("iphone", "40x40", "3x"),
        ("iphone", "60x60", "2x"),
        ("iphone", "60x60", "3x"),
        ("ipad", "20x20", "1x"),
        ("ipad", "20x20", "2x"),
        ("ipad", "29x29", "1x"),
        ("ipad", "29x29", "2x"),
        ("ipad", "40x40", "1x"),
        ("ipad", "40x40", "2x"),
        ("ipad", "76x76", "1x"),
        ("ipad", "76x76", "2x"),
        ("ipad", "83.5x83.5", "2x"),
        ("ios-marketing", "1024x1024", "1x"),
    }
else:
    raise SystemExit(f"Unsupported mode: {mode}")

entries = {}
for image in images:
    if not isinstance(image, dict):
        continue
    idiom = image.get("idiom")
    size = image.get("size")
    scale = image.get("scale")
    filename = image.get("filename")
    if not all([idiom, size, scale, filename]):
        continue
    entries[(idiom, size, scale)] = filename

missing = [k for k in sorted(required) if k not in entries]
if missing:
    detail = ", ".join(f"{idiom}:{size}@{scale}" for idiom, size, scale in missing)
    raise SystemExit(f"Missing required AppIcon entries: {detail}")

for idiom, size, scale in sorted(required):
    filename = entries[(idiom, size, scale)]
    size_width = float(size.split("x", 1)[0])
    scale_mult = int(scale.rstrip("x"))
    px = int(round(size_width * scale_mult))
    print(f"{filename}\t{px}x{px}\t{idiom}:{size}@{scale}")
PY
}

verify_devstation() {
  local pbx="$REPO_ROOT/apps/dev-station/DevStation.xcodeproj/project.pbxproj"
  local iconset="$REPO_ROOT/apps/dev-station/DevStation/Assets.xcassets/AppIcon.appiconset"
  local contents="$iconset/Contents.json"

  require_file "$pbx" "DevStation project file"
  require_dir "$iconset" "DevStation AppIcon set"
  require_file "$contents" "DevStation AppIcon Contents.json"

  require_text "$pbx" "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" "DevStation AppIcon build setting"
  require_text "$pbx" "Assets.xcassets */ = {isa = PBXFileReference;" "DevStation asset catalog file reference"
  require_text "$pbx" "Assets.xcassets in Resources" "DevStation asset catalog resources build phase entry"

  while IFS=$'\t' read -r filename expected context; do
    local path="$iconset/$filename"
    require_file "$path" "DevStation icon image ($context)"
    expect_dims "$path" "$expected" "DevStation icon image ($context)"
  done < <(expected_entries_from_contents "$contents" "devstation")

  pass "DevStation icon wiring and asset sizes are valid"
}

verify_scanner_ios() {
  local pbx="$REPO_ROOT/apps/sods-scanner-ios/SODSScanneriOS.xcodeproj/project.pbxproj"
  local iconset="$REPO_ROOT/apps/sods-scanner-ios/SODSScanneriOS/Assets.xcassets/AppIcon.appiconset"
  local contents="$iconset/Contents.json"

  require_file "$pbx" "SODSScanneriOS project file"
  require_dir "$iconset" "SODSScanneriOS AppIcon set"
  require_file "$contents" "SODSScanneriOS AppIcon Contents.json"

  require_text "$pbx" "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" "SODSScanneriOS AppIcon build setting"
  require_text "$pbx" "Assets.xcassets */ = {isa = PBXFileReference;" "SODSScanneriOS asset catalog file reference"
  require_text "$pbx" "Assets.xcassets in Resources" "SODSScanneriOS asset catalog resources build phase entry"

  while IFS=$'\t' read -r filename expected context; do
    local path="$iconset/$filename"
    require_file "$path" "SODSScanneriOS icon image ($context)"
    expect_dims "$path" "$expected" "SODSScanneriOS icon image ($context)"
  done < <(expected_entries_from_contents "$contents" "scanner-ios")

  pass "SODSScanneriOS iPhone+iPad icon wiring and asset sizes are valid"
}

TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || fail "--target requires a value"
      TARGET="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$TARGET" ]] || fail "Missing required --target argument"

case "$TARGET" in
  devstation)
    verify_devstation
    ;;
  scanner-ios)
    verify_scanner_ios
    ;;
  all)
    verify_devstation
    verify_scanner_ios
    ;;
  *)
    fail "Invalid target '$TARGET'. Expected devstation, scanner-ios, or all"
    ;;
esac

pass "Icon verification complete for target '$TARGET'"
