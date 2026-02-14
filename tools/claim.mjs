#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";

const args = process.argv.slice(2);
const auxHost = process.env.AUX_HOST || "pi-aux.local";
const loggerHost = process.env.LOGGER_HOST || "pi-logger.local";
const opts = {
  port: "auto",
  board: "",
  fwVersion: "",
  timeoutMs: 15000,
  claimCode: "",
  godUrl: process.env.GOD_GATEWAY_URL || `http://${auxHost}:8099/god`,
  vaultUrl: process.env.VAULT_INGEST_URL || `http://${loggerHost}:8088/v1/ingest`,
};

function fail(message, code = 2) {
  process.stderr.write(`${message}\n`);
  process.exit(code);
}

for (let i = 0; i < args.length; i += 1) {
  const token = args[i];
  if (token === "--port") {
    opts.port = String(args[i + 1] || "").trim();
    i += 1;
    continue;
  }
  if (token === "--board") {
    opts.board = String(args[i + 1] || "").trim();
    i += 1;
    continue;
  }
  if (token === "--fw-version") {
    opts.fwVersion = String(args[i + 1] || "").trim();
    i += 1;
    continue;
  }
  if (token === "--timeout-ms") {
    opts.timeoutMs = Number(args[i + 1] || "15000");
    i += 1;
    continue;
  }
  if (token === "--claim-code") {
    opts.claimCode = String(args[i + 1] || "").trim();
    i += 1;
    continue;
  }
  if (token === "--help" || token === "-h") {
    process.stdout.write("usage: node tools/claim.mjs --board <board_id> --fw-version <ver> [--port auto|/dev/tty...] [--timeout-ms 15000]\n");
    process.stdout.write("optional: --claim-code <code> (skip serial capture)\n");
    process.exit(0);
  }
  fail(`unknown argument: ${token}`, 64);
}

if (!opts.board) fail("--board is required", 64);
if (!opts.fwVersion) fail("--fw-version is required", 64);

function detectPort() {
  if (opts.port && opts.port !== "auto") return opts.port;
  const shell = process.platform === "darwin"
    ? "ls -1 /dev/tty.usb* /dev/tty.SLAB* /dev/tty.wch* 2>/dev/null | tail -n 1"
    : "ls -1 /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | tail -n 1";
  const out = spawnSync("/bin/sh", ["-lc", shell], { encoding: "utf8" });
  const value = String(out.stdout || "").trim();
  if (!value) fail("no serial port detected; pass --port <path>");
  return value;
}

function readClaimCodeFromSerial(port, timeoutMs) {
  const py = `
import re, sys, time
try:
    import serial
except Exception:
    print("PY_SERIAL_MISSING", file=sys.stderr)
    sys.exit(10)
port = sys.argv[1]
timeout_ms = int(sys.argv[2])
deadline = time.time() + timeout_ms / 1000.0
pat = re.compile(r"CLAIM_CODE[:=]\\s*([A-Za-z0-9_-]{4,64})")
try:
    ser = serial.Serial(port, 115200, timeout=0.2)
except Exception as e:
    print(f"SERIAL_OPEN_FAILED:{e}", file=sys.stderr)
    sys.exit(11)
try:
    buf = ""
    while time.time() < deadline:
        data = ser.read(512)
        if not data:
            continue
        chunk = data.decode("utf-8", "ignore")
        buf += chunk
        m = pat.search(buf)
        if m:
            print(m.group(1))
            sys.exit(0)
    print("CLAIM_CODE_NOT_FOUND", file=sys.stderr)
    sys.exit(12)
finally:
    try:
        ser.close()
    except Exception:
        pass
`;
  const out = spawnSync("python3", ["-c", py, port, String(timeoutMs)], { encoding: "utf8" });
  if (out.status !== 0) {
    const err = String(out.stderr || out.stdout || "").trim();
    fail(`claim serial read failed: ${err}`);
  }
  const code = String(out.stdout || "").trim();
  if (!code) fail("claim serial read returned empty code");
  return code;
}

async function postJson(url, payload) {
  const rsp = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
  const text = await rsp.text();
  return { ok: rsp.ok, status: rsp.status, text };
}

function event(type, data) {
  return {
    type,
    src: "claim-tool",
    ts_ms: Date.now(),
    data,
  };
}

const port = detectPort();
const claimCode = opts.claimCode || readClaimCodeFromSerial(port, opts.timeoutMs);
const normalizedClaimCode = String(claimCode || "").trim();
const macLike = /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/i.test(normalizedClaimCode) ? normalizedClaimCode.toLowerCase() : "";
const requestId = `claim-${Date.now()}-${crypto.randomBytes(3).toString("hex")}`;
const payload = {
  action: "node.claim",
  scope: "node",
  target: null,
  request_id: requestId,
  reason: "post-flash-claim",
  ts_ms: Date.now(),
  args: {
    claim_code: normalizedClaimCode,
    device_id: normalizedClaimCode,
    mac: macLike,
    board_id: opts.board,
    fw_version: opts.fwVersion,
    serial_port: port,
  },
};

await postJson(opts.vaultUrl, event("node.claim.intent", {
  request_id: requestId,
  node_id: null,
  device_id: normalizedClaimCode,
  board_id: opts.board,
  fw_version: opts.fwVersion,
  serial_port: port,
  claim_code: normalizedClaimCode,
}));

const godRsp = await postJson(opts.godUrl, payload);
const resultOk = godRsp.ok;

await postJson(opts.vaultUrl, event("node.claim.result", {
  request_id: requestId,
  node_id: null,
  device_id: normalizedClaimCode,
  board_id: opts.board,
  fw_version: opts.fwVersion,
  serial_port: port,
  claim_code: normalizedClaimCode,
  ok: resultOk,
  gateway_status: godRsp.status,
  gateway_body: godRsp.text,
}));

if (!resultOk) {
  fail(`node.claim failed via gateway (${godRsp.status}): ${godRsp.text}`);
}

process.stdout.write(JSON.stringify({
  ok: true,
  request_id: requestId,
  claim_code: normalizedClaimCode,
  board_id: opts.board,
  fw_version: opts.fwVersion,
  serial_port: port,
  control_plane_url: opts.godUrl,
}, null, 2));
process.stdout.write("\n");
