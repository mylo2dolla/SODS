#!/usr/bin/env python3
import datetime
import re
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RESOURCES_DIR = REPO_ROOT / "apps" / "dev-station" / "DevStation" / "Resources"

COMPANY_URL = "https://bitbucket.org/bluetooth-SIG/public/raw/HEAD/assigned_numbers/company_identifiers/company_identifiers.yaml"
SERVICE_URL = "https://bitbucket.org/bluetooth-SIG/public/raw/HEAD/assigned_numbers/uuids/service_uuids.yaml"
CHARACTERISTIC_URL = "https://bitbucket.org/bluetooth-SIG/public/raw/HEAD/assigned_numbers/uuids/characteristic_uuids.yaml"
DESCRIPTOR_URL = "https://bitbucket.org/bluetooth-SIG/public/raw/HEAD/assigned_numbers/uuids/descriptors.yaml"

COMPANY_OUT = RESOURCES_DIR / "BLECompanyIDs.txt"
ASSIGNED_OUT = RESOURCES_DIR / "BLEAssignedNumbers.txt"
SERVICE_OUT = RESOURCES_DIR / "BLEServiceUUIDs.txt"

MIN_COMPANIES = 3_900
MIN_ASSIGNED = 600
MIN_SERVICES = 75

VALUE_PATTERN = re.compile(r"^\s*-\s*value:\s*0x([0-9A-Fa-f]+)\s*$")
UUID_PATTERN = re.compile(r"^\s*-\s*uuid:\s*0x([0-9A-Fa-f]+)\s*$")
NAME_PATTERN = re.compile(r"^\s*name:\s*(.+?)\s*$")


def fetch_text(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "SODS-refresh-ble-metadata/1.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8", "ignore")


def decode_yaml_scalar(raw: str) -> str:
    value = raw.strip()
    if value.startswith("'") and value.endswith("'") and len(value) >= 2:
        return value[1:-1].replace("''", "'")
    if value.startswith('"') and value.endswith('"') and len(value) >= 2:
        inner = value[1:-1]
        return bytes(inner, "utf-8").decode("unicode_escape")
    return value


def parse_company_yaml(text: str) -> dict[int, str]:
    result: dict[int, str] = {}
    current_value: int | None = None

    for raw_line in text.splitlines():
        value_match = VALUE_PATTERN.match(raw_line)
        if value_match:
            current_value = int(value_match.group(1), 16)
            continue

        name_match = NAME_PATTERN.match(raw_line)
        if name_match and current_value is not None:
            name = decode_yaml_scalar(name_match.group(1)).strip()
            if name:
                result[current_value] = name
            current_value = None

    return result


def parse_uuid_yaml(text: str) -> dict[int, str]:
    result: dict[int, str] = {}
    current_uuid: int | None = None

    for raw_line in text.splitlines():
        uuid_match = UUID_PATTERN.match(raw_line)
        if uuid_match:
            current_uuid = int(uuid_match.group(1), 16)
            continue

        name_match = NAME_PATTERN.match(raw_line)
        if name_match and current_uuid is not None:
            name = decode_yaml_scalar(name_match.group(1)).strip()
            if name:
                result[current_uuid] = name
            current_uuid = None

    return result


def format_hex(value: int) -> str:
    width = max(4, len(f"{value:X}"))
    return f"0x{value:0{width}X}"


def write_company_file(path: Path, companies: dict[int, str], updated: str) -> None:
    lines = [
        "# Bluetooth SIG Company Identifiers",
        f"# Source: {COMPANY_URL}",
        f"# Updated: {updated}",
    ]
    for company_id in sorted(companies):
        lines.append(f"{format_hex(company_id)} {companies[company_id]}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_assigned_file(path: Path, services: dict[int, str], characteristics: dict[int, str], descriptors: dict[int, str], updated: str) -> None:
    lines = [
        "# Bluetooth SIG Assigned Numbers (Services, Characteristics, Descriptors)",
        f"# Source: {SERVICE_URL}, {CHARACTERISTIC_URL}, {DESCRIPTOR_URL}",
        f"# Updated: {updated}",
    ]

    combined: dict[int, tuple[str, str]] = {}
    for uuid, name in sorted(services.items()):
        combined.setdefault(uuid, ("service", name))
    for uuid, name in sorted(characteristics.items()):
        combined.setdefault(uuid, ("characteristic", name))
    for uuid, name in sorted(descriptors.items()):
        combined.setdefault(uuid, ("descriptor", name))

    for uuid in sorted(combined):
        kind, name = combined[uuid]
        lines.append(f"{format_hex(uuid)} {kind} {name}")

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_service_file(path: Path, services: dict[int, str], updated: str) -> None:
    lines = [
        "# Bluetooth SIG Service UUIDs",
        f"# Source: {SERVICE_URL}",
        f"# Updated: {updated}",
    ]
    for uuid in sorted(services):
        lines.append(f"{format_hex(uuid)} {services[uuid]}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    companies = parse_company_yaml(fetch_text(COMPANY_URL))
    services = parse_uuid_yaml(fetch_text(SERVICE_URL))
    characteristics = parse_uuid_yaml(fetch_text(CHARACTERISTIC_URL))
    descriptors = parse_uuid_yaml(fetch_text(DESCRIPTOR_URL))

    assigned_count = len(set(services) | set(characteristics) | set(descriptors))

    if len(companies) < MIN_COMPANIES:
        raise RuntimeError(f"company count too low: {len(companies)} < {MIN_COMPANIES}")
    if len(services) < MIN_SERVICES:
        raise RuntimeError(f"service count too low: {len(services)} < {MIN_SERVICES}")
    if assigned_count < MIN_ASSIGNED:
        raise RuntimeError(f"assigned count too low: {assigned_count} < {MIN_ASSIGNED}")

    updated = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d")
    RESOURCES_DIR.mkdir(parents=True, exist_ok=True)

    write_company_file(COMPANY_OUT, companies, updated)
    write_assigned_file(ASSIGNED_OUT, services, characteristics, descriptors, updated)
    write_service_file(SERVICE_OUT, services, updated)

    print(f"OK: companies={len(companies)}")
    print(f"OK: assigned={assigned_count} (service={len(services)} characteristic={len(characteristics)} descriptor={len(descriptors)})")
    print(f"OK: wrote {COMPANY_OUT}")
    print(f"OK: wrote {ASSIGNED_OUT}")
    print(f"OK: wrote {SERVICE_OUT}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"refresh-ble-metadata failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
