import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";

export function logInfo(message) {
  process.stdout.write(`${message}\n`);
}

export function logError(message) {
  process.stderr.write(`${message}\n`);
}

export function fail(message, code = 2) {
  throw Object.assign(new Error(message), { exitCode: code });
}

export function parseArgs(argv) {
  const args = {
    board: "",
    version: "",
    all: false,
    skipBuild: false,
    dryRun: false,
    port: "",
    erase: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === "--board") {
      args.board = String(argv[i + 1] || "").trim();
      i += 1;
      continue;
    }
    if (token === "--version") {
      args.version = String(argv[i + 1] || "").trim();
      i += 1;
      continue;
    }
    if (token === "--port") {
      args.port = String(argv[i + 1] || "").trim();
      i += 1;
      continue;
    }
    if (token === "--all") {
      args.all = true;
      continue;
    }
    if (token === "--skip-build") {
      args.skipBuild = true;
      continue;
    }
    if (token === "--dry-run") {
      args.dryRun = true;
      continue;
    }
    if (token === "--erase") {
      args.erase = true;
      continue;
    }
    if (token === "--help" || token === "-h") {
      args.help = true;
      continue;
    }
    fail(`unknown argument: ${token}`, 64);
  }
  return args;
}

export function safeMkdir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

export function fileExists(filePath) {
  try {
    return fs.existsSync(filePath);
  } catch {
    return false;
  }
}

export function requireFile(filePath, label) {
  if (!fileExists(filePath)) {
    fail(`${label} missing: ${filePath}`);
  }
}

export function readJson(filePath, label = "json file") {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    fail(`failed to parse ${label} (${filePath}): ${String(error?.message || error)}`);
  }
}

export function writeJson(filePath, value) {
  safeMkdir(path.dirname(filePath));
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

export function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  const content = fs.readFileSync(filePath);
  hash.update(content);
  return hash.digest("hex");
}

export function copyFile(src, dst) {
  safeMkdir(path.dirname(dst));
  fs.copyFileSync(src, dst);
}

export function run(cmd, args, options = {}) {
  const result = spawnSync(cmd, args, {
    cwd: options.cwd,
    env: options.env || process.env,
    encoding: "utf8",
    timeout: Number(options.timeoutMs || 0) || undefined,
    stdio: options.capture === true ? "pipe" : "inherit",
  });
  if (result.status !== 0) {
    const stderr = String(result.stderr || "").trim();
    const stdout = String(result.stdout || "").trim();
    const hint = stderr || stdout || `${cmd} failed`;
    fail(hint, result.status || 2);
  }
  return result;
}

export function tryRun(cmd, args, options = {}) {
  return spawnSync(cmd, args, {
    cwd: options.cwd,
    env: options.env || process.env,
    encoding: "utf8",
    timeout: Number(options.timeoutMs || 0) || undefined,
    stdio: "pipe",
  });
}

export function commandExists(cmd) {
  const out = tryRun("/bin/sh", ["-lc", `command -v "${cmd}"`]);
  return out.status === 0;
}

export function resolveGitCommit(repoRoot) {
  const out = tryRun("git", ["-C", repoRoot, "rev-parse", "HEAD"]);
  if (out.status !== 0) return "unknown";
  return String(out.stdout || "").trim() || "unknown";
}

export function resolveToolVersion(cmd, args = ["--version"]) {
  const out = tryRun(cmd, args);
  if (out.status !== 0) return "unknown";
  const raw = `${String(out.stdout || "")}\n${String(out.stderr || "")}`.trim();
  return raw.split(/\r?\n/).find(Boolean) || "unknown";
}

export function resolveEsptoolVersion() {
  const candidates = [
    { cmd: "esptool", args: ["version"] },
    { cmd: "esptool.py", args: ["version"] },
    { cmd: "python3", args: ["-m", "esptool", "version"] },
  ];
  for (const candidate of candidates) {
    const out = tryRun(candidate.cmd, candidate.args);
    if (out.status !== 0) continue;
    const text = `${String(out.stdout || "")}\n${String(out.stderr || "")}`;
    const line = text.split(/\r?\n/).map((s) => s.trim()).find((s) => /^esptool\s+v?\d/i.test(s) || /^\d+\.\d+/.test(s));
    if (line) return line;
  }
  return "unknown";
}

export function readBoards(repoRoot) {
  const boardsPath = path.join(repoRoot, "firmware", "boards.json");
  const data = readJson(boardsPath, "boards.json");
  const rawBoards = Array.isArray(data?.boards) ? data.boards : [];
  const boards = new Map();
  for (const board of rawBoards) {
    if (!board || typeof board !== "object") continue;
    const id = String(board.board_id || "").trim();
    if (!id) continue;
    boards.set(id, board);
  }
  if (boards.size === 0) {
    fail(`no boards defined in ${boardsPath}`);
  }
  return boards;
}

export function selectBoards(args, supportedBoardIds) {
  if (args.all) return [...supportedBoardIds];
  if (!args.board) fail("--board <board_id> or --all is required", 64);
  const requested = args.board.split(",").map((v) => v.trim()).filter(Boolean);
  if (requested.length === 0) fail("at least one board_id is required", 64);
  for (const boardId of requested) {
    if (!supportedBoardIds.includes(boardId)) {
      fail(`unsupported board for this app: ${boardId}`);
    }
  }
  return requested;
}

export function resolveVersion(args) {
  if (args.version) return args.version;
  const d = new Date();
  const stamp = [
    d.getUTCFullYear(),
    String(d.getUTCMonth() + 1).padStart(2, "0"),
    String(d.getUTCDate()).padStart(2, "0"),
    String(d.getUTCHours()).padStart(2, "0"),
    String(d.getUTCMinutes()).padStart(2, "0"),
    String(d.getUTCSeconds()).padStart(2, "0"),
  ].join("");
  return `dev-${stamp}`;
}

export function writeShaFile(outDir, files) {
  const lines = [];
  for (const fileName of files) {
    const filePath = path.join(outDir, fileName);
    const digest = sha256File(filePath);
    lines.push(`${digest}  ${fileName}`);
  }
  fs.writeFileSync(path.join(outDir, "sha256sums.txt"), `${lines.join("\n")}\n`, "utf8");
}

export function buildInfoBase({ app, boardId, version, repoRoot }) {
  return {
    app,
    board_id: boardId,
    version,
    git_commit: resolveGitCommit(repoRoot),
    build_ts_ms: Date.now(),
    idf_version: process.env.IDF_VERSION || resolveToolVersion("idf.py"),
    esptool_version: resolveEsptoolVersion(),
  };
}

export function firstExisting(paths) {
  for (const p of paths) {
    if (fileExists(p)) return p;
  }
  return "";
}

export function listSerialPorts() {
  const patterns = process.platform === "darwin"
    ? [
      "/dev/cu.usb*",
      "/dev/cu.SLAB*",
      "/dev/cu.wch*",
      "/dev/cu.usbserial*",
      "/dev/tty.usb*",
      "/dev/tty.SLAB*",
      "/dev/tty.wch*",
      "/dev/tty.usbserial*",
    ]
    : ["/dev/ttyUSB*", "/dev/ttyACM*", "/dev/ttyAMA*"];
  const found = [];
  for (const pattern of patterns) {
    const out = tryRun("/bin/sh", ["-lc", `ls -1 ${pattern} 2>/dev/null || true`]);
    if (out.status !== 0) continue;
    for (const line of String(out.stdout || "").split(/\r?\n/)) {
      const port = line.trim();
      if (port) found.push(port);
    }
  }
  return [...new Set(found)];
}

export function detectPort(portArg) {
  if (portArg && portArg !== "auto") return portArg;
  const ports = listSerialPorts();
  if (ports.length === 0) fail("no serial ports detected; pass --port <path>");
  const sorted = [...ports].sort();
  if (process.platform === "darwin") {
    const preferred = sorted.filter((p) => p.startsWith("/dev/cu."));
    if (preferred.length > 0) return preferred[preferred.length - 1];
  }
  return sorted[sorted.length - 1];
}

export function checkPortBusy(portPath) {
  const out = tryRun("/bin/sh", ["-lc", `lsof "${portPath}" 2>/dev/null || true`]);
  const text = String(out.stdout || "").trim();
  if (!text) return null;
  const lines = text.split(/\r?\n/);
  return lines.slice(0, 6).join("\n");
}

export function chooseEsptool() {
  const envBin = String(process.env.ESPTOOL_BIN || "").trim();
  if (envBin) {
    return { cmd: envBin, prefixArgs: [], label: envBin, version: resolveToolVersion(envBin, ["version"]) };
  }

  const binaryCandidates = [
    "esptool",
    "esptool.py",
    "/opt/homebrew/bin/esptool",
    "/opt/homebrew/bin/esptool.py",
    "/usr/local/bin/esptool",
    "/usr/local/bin/esptool.py",
    "/usr/bin/esptool",
    "/usr/bin/esptool.py",
  ];
  for (const candidate of binaryCandidates) {
    const out = tryRun("/bin/sh", ["-lc", `command -v "${candidate}"`]);
    if (out.status !== 0) continue;
    const resolved = String(out.stdout || "").trim() || candidate;
    return { cmd: resolved, prefixArgs: [], label: resolved, version: resolveToolVersion(resolved, ["version"]) };
  }

  const moduleOut = tryRun("python3", ["-m", "esptool", "version"]);
  if (moduleOut.status === 0) {
    const text = `${String(moduleOut.stdout || "")}\n${String(moduleOut.stderr || "")}`.trim();
    const version = text.split(/\r?\n/).find((line) => /^esptool\s+v?\d/i.test(line) || /^\d+\.\d+/.test(line)) || text || "unknown";
    return { cmd: "python3", prefixArgs: ["-m", "esptool"], label: "python3 -m esptool", version };
  }

  fail("esptool not found. Install esptool or set ESPTOOL_BIN.");
}

export function runEsptool(esptool, args, options = {}) {
  return run(esptool.cmd, [...(esptool.prefixArgs || []), ...args], options);
}

export function tryEsptool(esptool, args, options = {}) {
  return tryRun(esptool.cmd, [...(esptool.prefixArgs || []), ...args], options);
}

export function selectVersionDir(baseDir, requestedVersion = "") {
  if (requestedVersion) {
    const p = path.join(baseDir, requestedVersion);
    requireFile(p, "version directory");
    return p;
  }
  if (!fileExists(baseDir)) fail(`version base directory missing: ${baseDir}`);
  const entries = fs.readdirSync(baseDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort();
  if (entries.length === 0) fail(`no version directories in ${baseDir}`);
  return path.join(baseDir, entries[entries.length - 1]);
}

export function normalizeManifestParts(parts) {
  return parts.map((part) => ({
    path: String(part.path),
    offset: Number(part.offset),
  }));
}
