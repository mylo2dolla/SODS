#!/usr/bin/env python3
import os
import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent

IEEE_SOURCES = [
    REPO_ROOT / "data" / "resources" / "oui.txt",
    REPO_ROOT / "data" / "resources" / "oui 2.txt",
]

# This file already exists in-repo and typically reflects a prior merge of IEEE + Wireshark manuf.
COMBINED_OVERRIDE = REPO_ROOT / "data" / "strangelab" / "StrangeLab" / "oui" / "oui_combined.txt"

OUT_DIR = REPO_ROOT / "OUI"
OUT_COMBINED = OUT_DIR / "oui_combined.txt"
OUT_DEVSTATION_RESOURCE = REPO_ROOT / "apps" / "dev-station" / "DevStation" / "Resources" / "OUI.txt"

RUNTIME_OUT = Path.home() / "SODS" / "oui" / "oui_combined.txt"


def normalize_key(token: str) -> str | None:
    t = re.sub(r"[^0-9A-Fa-f]", "", token or "").upper()
    if len(t) < 6:
        return None
    return t[:6]


def format_key_hyphen(key6: str) -> str:
    return f"{key6[0:2]}-{key6[2:4]}-{key6[4:6]}"


def load_ieee(path: Path, out: dict[str, str]) -> int:
    if not path.exists():
        return 0

    pat_hex = re.compile(r"^([0-9A-F]{2}-[0-9A-F]{2}-[0-9A-F]{2})\s+\(hex\)\s+(.+)$", re.I)
    pat_base16 = re.compile(r"^([0-9A-F]{6})\s+\(base\s+16\)\s+(.+)$", re.I)

    count = 0
    with path.open("r", errors="ignore") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            m = pat_hex.match(line)
            if m:
                key = normalize_key(m.group(1))
                vendor = (m.group(2) or "").strip()
                if key and vendor:
                    out[key] = vendor
                    count += 1
                continue
            m = pat_base16.match(line)
            if m:
                key = normalize_key(m.group(1))
                vendor = (m.group(2) or "").strip()
                if key and vendor:
                    out[key] = vendor
                    count += 1
                continue
    return count


def load_combined_override(path: Path, out: dict[str, str]) -> int:
    if not path.exists():
        return 0

    count = 0
    with path.open("r", errors="ignore") as f:
        for raw in f:
            line = raw.rstrip("\n").strip()
            if not line or line.startswith("#"):
                continue
            parts = re.split(r"\s+", line, maxsplit=1)
            if len(parts) < 2:
                continue
            key = normalize_key(parts[0])
            if not key:
                continue
            vendor_blob = parts[1].strip()
            # Historical combined files sometimes carry: "SHORT<TAB>Full Vendor"
            if "\t" in vendor_blob:
                vendor = vendor_blob.split("\t")[-1].strip()
            else:
                vendor = vendor_blob
            if vendor:
                out[key] = vendor
                count += 1
    return count


def write_combined(path: Path, mapping: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for key in sorted(mapping.keys()):
            vendor = mapping[key].strip()
            if not vendor:
                continue
            f.write(f"{format_key_hyphen(key)}\t{vendor}\n")


def main() -> int:
    mapping: dict[str, str] = {}

    ieee_rows = 0
    for src in IEEE_SOURCES:
        ieee_rows += load_ieee(src, mapping)

    override_rows = load_combined_override(COMBINED_OVERRIDE, mapping)

    if len(mapping) < 1000:
        raise SystemExit(
            f"OUI rebuild failed: too few entries ({len(mapping)}). "
            f"Check sources: {', '.join(str(p) for p in IEEE_SOURCES)}"
        )

    write_combined(OUT_COMBINED, mapping)
    write_combined(OUT_DEVSTATION_RESOURCE, mapping)

    # Best-effort install into runtime location used by DevStation (user override path).
    RUNTIME_OUT.parent.mkdir(parents=True, exist_ok=True)
    write_combined(RUNTIME_OUT, mapping)

    print(f"OK: entries={len(mapping)}")
    print(f"OK: wrote {OUT_COMBINED}")
    print(f"OK: wrote {OUT_DEVSTATION_RESOURCE}")
    print(f"OK: wrote {RUNTIME_OUT}")
    print(f"info: ieee_rows_parsed={ieee_rows} override_rows_parsed={override_rows}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
