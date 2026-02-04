#!/usr/bin/env bash
set -euo pipefail

pattern="${1:-}"
AIRPORT=""
WDUTIL=""

known_paths=(
  "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
  "/System/Library/PrivateFrameworks/Apple80211.framework/Resources/airport"
)

for path in "${known_paths[@]}"; do
  if [[ -x "$path" ]]; then
    AIRPORT="$path"
    break
  fi
done

if [[ -z "$AIRPORT" ]]; then
  while IFS= read -r candidate; do
    [[ "$candidate" == */airport ]] || continue
    if [[ -x "$candidate" ]]; then
      AIRPORT="$candidate"
      break
    fi
  done < <(mdfind 'kMDItemFSName == "airport"' 2>/dev/null || true)
fi

if [[ -z "$AIRPORT" ]]; then
  if command -v wdutil >/dev/null 2>&1; then
    WDUTIL="$(command -v wdutil)"
  else
    echo "wifi-scan: airport binary not found on this macOS build" >&2
    echo "wifi-scan: install Wi-Fi tools or verify Apple80211.framework" >&2
    exit 2
  fi
fi

if [[ -n "$AIRPORT" ]]; then
  output="$("$AIRPORT" -s 2>&1)" || {
    if echo "$output" | grep -qi "permission"; then
      output="$(sudo "$AIRPORT" -s 2>&1)" || {
        echo "$output" >&2
        exit 1
      }
    else
      echo "$output" >&2
      exit 1
    fi
  }
else
  output="$("$WDUTIL" scan 2>&1)" || true
  if echo "$output" | grep -qi "^usage: sudo wdutil"; then
    output="$(sudo "$WDUTIL" scan 2>&1)" || true
  fi
  if echo "$output" | grep -qi "^usage: sudo wdutil"; then
    output="$(system_profiler SPAirPortDataType 2>&1)" || {
      echo "$output" >&2
      exit 1
    }
  fi
fi

if [[ -n "$pattern" ]]; then
  echo "$output" | grep -E "$pattern" || true
else
  echo "$output"
fi
