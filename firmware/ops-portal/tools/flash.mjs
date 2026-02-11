#!/usr/bin/env node
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  parseArgs,
  readBoards,
  selectVersionDir,
  detectPort,
  checkPortBusy,
  chooseEsptool,
  runEsptool,
  tryEsptool,
  requireFile,
  fail,
  logInfo,
} from "../../tools/fw-common.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const appRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(appRoot, "..", "..");
const webToolsRoot = path.join(appRoot, "esp-web-tools");
const SUPPORTED = ["cyd-2432s028"];

function usage() {
  logInfo("usage: node tools/flash.mjs --board cyd-2432s028 [--version <ver>] [--port auto|/dev/tty...] [--erase] [--dry-run] [--strict-chip-check]");
}

function ensureChipMatch(esptool, board, port) {
  const out = tryEsptool(
    esptool,
    ["--port", port, "--before", "default_reset", "--after", "no_reset", "chip_id"],
    { timeoutMs: 15000 }
  );
  if (out.error?.code === "ETIMEDOUT") {
    fail(`esptool chip_id timed out on ${port}. Use --port /dev/cu.* on macOS and check cable/boot mode.`);
  }
  if (out.status !== 0) {
    fail(`esptool chip_id failed on ${port}: ${String(out.stderr || out.stdout || "").trim()}`);
  }
  const normalize = (value) => String(value || "").toLowerCase().replace(/[^a-z0-9]/g, "");
  const text = normalize(`${String(out.stdout || "")}\n${String(out.stderr || "")}`);
  const chipNeedle = normalize(board.chip);
  if (chipNeedle && !text.includes(chipNeedle)) {
    fail(`connected chip does not match board (${board.board_id}). output: ${text.trim()}`);
  }
}

function shouldSkipChipCheck(argv) {
  return !argv.includes("--strict-chip-check");
}

try {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    process.exit(0);
  }
  if (!args.board) fail("--board is required", 64);
  if (!SUPPORTED.includes(args.board)) fail(`unsupported board: ${args.board}`);

  const boards = readBoards(repoRoot);
  const board = boards.get(args.board);
  if (!board) fail(`board_id missing from boards.json: ${args.board}`);

  const versionBase = path.join(webToolsRoot, "firmware", board.board_id);
  const versionDir = selectVersionDir(versionBase, args.version);
  const boot = path.join(versionDir, "bootloader.bin");
  const part = path.join(versionDir, "partition-table.bin");
  const app0 = path.join(versionDir, "boot_app0.bin");
  const fw = path.join(versionDir, "firmware.bin");
  requireFile(boot, "bootloader");
  requireFile(part, "partition-table");
  requireFile(app0, "boot_app0");
  requireFile(fw, "firmware");

  const port = detectPort(args.port || "auto");
  requireFile(port, "serial port");
  const esptool = chooseEsptool();
  const baud = String(board.default_baud || 460800);
  const offsets = board.offsets || {};
  const writeArgs = [
    "--chip", board.chip,
    "--port", port,
    "--before", "default_reset",
    "--after", "hard_reset",
    "--baud", baud,
    "write_flash",
    "-z",
    String(Number(offsets.bootloader || 0)), boot,
    String(Number(offsets["partition-table"] || offsets.partition || 0)), part,
    String(Number(offsets.boot_app0 || 0)), app0,
    String(Number(offsets.firmware || 0)), fw,
  ];

  logInfo(`[flash:preflight] board=${board.board_id}`);
  logInfo(`[flash:preflight] version=${path.basename(versionDir)}`);
  logInfo(`[flash:preflight] esptool=${esptool.label} (${esptool.version || "unknown"})`);
  logInfo(`[flash:preflight] port=${port}`);
  logInfo(`[flash:preflight] bootloader=${boot} @${Number(offsets.bootloader || 0)}`);
  logInfo(`[flash:preflight] partition-table=${part} @${Number(offsets["partition-table"] || offsets.partition || 0)}`);
  logInfo(`[flash:preflight] boot_app0=${app0} @${Number(offsets.boot_app0 || 0)}`);
  logInfo(`[flash:preflight] firmware=${fw} @${Number(offsets.firmware || 0)}`);

  const busy = checkPortBusy(port);
  if (busy) {
    fail(`serial port busy: ${port}\n${busy}`);
  }

  const skipChipCheck = shouldSkipChipCheck(process.argv.slice(2));
  if (skipChipCheck) {
    logInfo("[flash:preflight] chip-check=skipped");
  } else {
    ensureChipMatch(esptool, board, port);
  }

  if (args.dryRun) {
    logInfo(`[flash:dry-run] erase=${args.erase ? "yes" : "no"}`);
    logInfo(`[flash:dry-run] command=${esptool.label} ${writeArgs.join(" ")}`);
    process.exit(0);
  }

  if (args.erase) {
    logInfo(`[flash] erase ${board.board_id} on ${port}`);
    runEsptool(esptool, ["--chip", board.chip, "--port", port, "--baud", baud, "erase_flash"], { cwd: appRoot });
  }

  logInfo(`[flash] ${board.board_id} version=${path.basename(versionDir)} port=${port}`);
  runEsptool(esptool, writeArgs, { cwd: appRoot });
  logInfo("[flash] complete");
} catch (error) {
  process.stderr.write(`${String(error?.message || error)}\n`);
  process.exit(error?.exitCode || 2);
}
