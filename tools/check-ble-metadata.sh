#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_RES_DIR="$REPO_ROOT/apps/dev-station/DevStation/Resources"
COMPANY_FILE="$APP_RES_DIR/BLECompanyIDs.txt"
ASSIGNED_FILE="$APP_RES_DIR/BLEAssignedNumbers.txt"
SERVICE_FILE="$APP_RES_DIR/BLEServiceUUIDs.txt"
APP_OUI_FILE="$APP_RES_DIR/OUI.txt"
CANON_OUI_FILE="$REPO_ROOT/OUI/oui_combined.txt"

MIN_COMPANY_COUNT="${MIN_COMPANY_COUNT:-3900}"
MIN_ASSIGNED_COUNT="${MIN_ASSIGNED_COUNT:-590}"
MIN_SERVICE_COUNT="${MIN_SERVICE_COUNT:-70}"
MAX_PARSE_ERRORS="${MAX_PARSE_ERRORS:-20}"

for required in "$COMPANY_FILE" "$ASSIGNED_FILE" "$SERVICE_FILE" "$APP_OUI_FILE" "$CANON_OUI_FILE"; do
  if [[ ! -f "$required" ]]; then
    echo "check-ble-metadata: missing required file: $required" >&2
    exit 2
  fi
done

python3 - \
  "$COMPANY_FILE" \
  "$ASSIGNED_FILE" \
  "$SERVICE_FILE" \
  "$APP_OUI_FILE" \
  "$CANON_OUI_FILE" \
  "$MIN_COMPANY_COUNT" \
  "$MIN_ASSIGNED_COUNT" \
  "$MIN_SERVICE_COUNT" \
  "$MAX_PARSE_ERRORS" <<'PY'
import sys
from pathlib import Path

company_path = Path(sys.argv[1])
assigned_path = Path(sys.argv[2])
service_path = Path(sys.argv[3])
app_oui_path = Path(sys.argv[4])
canon_oui_path = Path(sys.argv[5])
min_company = int(sys.argv[6])
min_assigned = int(sys.argv[7])
min_service = int(sys.argv[8])
max_parse_errors = int(sys.argv[9])


def read_lines(path: Path):
    return path.read_text(encoding="utf-8", errors="ignore").splitlines()


def header_flags(lines):
    has_source = any(line.startswith("# Source:") for line in lines)
    has_updated = any(line.startswith("# Updated:") for line in lines)
    return has_source, has_updated


def parse_company(lines):
    count = 0
    errors = 0
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        if len(parts) < 2:
            errors += 1
            continue
        token = parts[0].lower()
        if token.startswith("0x"):
            token = token[2:]
        try:
            int(token, 16)
        except ValueError:
            errors += 1
            continue
        count += 1
    return count, errors


def parse_assigned(lines):
    count = 0
    errors = 0
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 3:
            errors += 1
            continue
        token = parts[0].lower()
        if token.startswith("0x"):
            token = token[2:]
        try:
            int(token, 16)
        except ValueError:
            errors += 1
            continue
        count += 1
    return count, errors


def parse_services(lines):
    count = 0
    errors = 0
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            errors += 1
            continue
        token = parts[0].lower()
        if token.startswith("0x"):
            token = token[2:]
        try:
            int(token, 16)
        except ValueError:
            errors += 1
            continue
        count += 1
    return count, errors


company_lines = read_lines(company_path)
assigned_lines = read_lines(assigned_path)
service_lines = read_lines(service_path)

company_count, company_errors = parse_company(company_lines)
assigned_count, assigned_errors = parse_assigned(assigned_lines)
service_count, service_errors = parse_services(service_lines)
parse_errors = company_errors + assigned_errors + service_errors

company_source, company_updated = header_flags(company_lines)
assigned_source, assigned_updated = header_flags(assigned_lines)
service_source, service_updated = header_flags(service_lines)

problems = []

if company_count < min_company:
    problems.append(f"BLECompanyIDs entries too low: {company_count} < {min_company}")
if assigned_count < min_assigned:
    problems.append(f"BLEAssignedNumbers entries too low: {assigned_count} < {min_assigned}")
if service_count < min_service:
    problems.append(f"BLEServiceUUIDs entries too low: {service_count} < {min_service}")
if parse_errors > max_parse_errors:
    problems.append(f"parse errors too high: {parse_errors} > {max_parse_errors}")

if not company_source or not company_updated:
    problems.append("BLECompanyIDs.txt missing required header lines (# Source / # Updated)")
if not assigned_source or not assigned_updated:
    problems.append("BLEAssignedNumbers.txt missing required header lines (# Source / # Updated)")
if not service_source or not service_updated:
    problems.append("BLEServiceUUIDs.txt missing required header lines (# Source / # Updated)")

if app_oui_path.read_bytes() != canon_oui_path.read_bytes():
    problems.append("OUI parity mismatch: app Resources/OUI.txt differs from OUI/oui_combined.txt")

print(
    "check-ble-metadata: "
    f"company={company_count} assigned={assigned_count} services={service_count} "
    f"parse_errors={parse_errors}"
)

if problems:
    for issue in problems:
        print(f"[FAIL] {issue}", file=sys.stderr)
    sys.exit(2)

print("check-ble-metadata: PASS")
PY
