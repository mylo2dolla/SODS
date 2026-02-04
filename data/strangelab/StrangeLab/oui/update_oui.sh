#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="$HOME/StrangeLab/oui"
TMP_DIR="$OUT_DIR/tmp"
OUT_TXT="$OUT_DIR/oui_combined.txt"

IEEE_URL="https://standards-oui.ieee.org/oui/oui.txt"
WIRESHARK_URL="https://www.wireshark.org/download/automated/data/manuf.gz"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

echo "[1/5] Download IEEE oui.txt"
curl -fsSL "$IEEE_URL" -o "$TMP_DIR/ieee_oui.txt"

echo "[2/5] Download Wireshark manuf.gz"
curl -fsSL "$WIRESHARK_URL" -o "$TMP_DIR/manuf.gz"
gzip -dc "$TMP_DIR/manuf.gz" > "$TMP_DIR/manuf.txt"

echo "[3/5] Normalize IEEE -> AABBCC Vendor"
python3 - <<'PY' > "$TMP_DIR/ieee_norm.txt"
import re
from pathlib import Path

src = Path.home() / "StrangeLab/oui/tmp/ieee_oui.txt"
out = []
pat = re.compile(r'^([0-9A-F]{2}-[0-9A-F]{2}-[0-9A-F]{2})\s+\(hex\)\s+(.+)$', re.I)

for line in src.read_text(errors="ignore").splitlines():
    m = pat.match(line.strip())
    if not m:
        continue
    oui = m.group(1).replace("-", "").upper()
    vendor = m.group(2).strip()
    if oui and vendor:
        out.append(f"{oui} {vendor}")

# de-dupe while preserving last occurrence
seen = {}
for row in out:
    k = row.split(" ", 1)[0]
    seen[k] = row
for k in sorted(seen.keys()):
    print(seen[k])
PY

echo "[4/5] Normalize Wireshark manuf -> AABBCC Vendor"
python3 - <<'PY' > "$TMP_DIR/manuf_norm.txt"
import re
from pathlib import Path

src = Path.home() / "StrangeLab/oui/tmp/manuf.txt"

def norm_oui(token: str):
    token = token.strip()
    if not token or token.startswith("#"):
        return None
    # Wireshark formats include:
    # 00:11:22  Vendor
    # 00-11-22  Vendor
    # 001122    Vendor
    # 00:11:22:33:44:55/24 Vendor  (ignore mask, keep first 3 bytes)
    token = token.split("/", 1)[0]
    token = token.replace("-", ":")
    if ":" in token:
        parts = token.split(":")
        if len(parts) < 3:
            return None
        parts = parts[:3]
        if any(len(p) != 2 or not all(c in "0123456789abcdefABCDEF" for c in p) for p in parts):
            return None
        return ("".join(parts)).upper()
    # plain hex
    token = re.sub(r'[^0-9A-Fa-f]', '', token)
    if len(token) < 6:
        return None
    return token[:6].upper()

seen = {}
for line in src.read_text(errors="ignore").splitlines():
    line = line.rstrip()
    if not line or line.lstrip().startswith("#"):
        continue
    # split on whitespace/tabs; first token is prefix, rest is vendor string
    parts = re.split(r"\s+", line.strip(), maxsplit=1)
    if len(parts) < 2:
        continue
    oui = norm_oui(parts[0])
    if not oui:
        continue
    vendor = parts[1].strip()
    if not vendor:
        continue
    # prefer Wireshark on collisions by writing last
    seen[oui] = f"{oui} {vendor}"

for k in sorted(seen.keys()):
    print(seen[k])
PY

echo "[5/5] Merge (Wireshark overrides IEEE) -> $OUT_TXT"
python3 - <<'PY'
from pathlib import Path

base = Path.home() / "StrangeLab/oui/tmp/ieee_norm.txt"
over = Path.home() / "StrangeLab/oui/tmp/manuf_norm.txt"
outf = Path.home() / "StrangeLab/oui/oui_combined.txt"

m = {}
def load(p: Path):
    for line in p.read_text(errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        k, v = line.split(" ", 1)
        m[k] = v

load(base)   # IEEE first
load(over)   # Wireshark overrides

with outf.open("w", encoding="utf-8") as f:
    for k in sorted(m.keys()):
        f.write(f"{k} {m[k]}\n")

print(f"Wrote {len(m)} OUIs to {outf}")
PY

echo "Done."
echo "Import this file in CamUtil: $OUT_TXT"
