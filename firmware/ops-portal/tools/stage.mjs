#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  parseArgs,
  readBoards,
  selectBoards,
  resolveVersion,
  run,
  firstExisting,
  copyFile,
  requireFile,
  sha256File,
  writeShaFile,
  writeJson,
  buildInfoBase,
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
  logInfo("usage: node tools/stage.mjs --board cyd-2432s028 --version <ver>");
  logInfo("   or: node tools/stage.mjs --all --version <ver>");
  logInfo("flags: --skip-build");
}

function stageBoard(board, version, skipBuild) {
  if (!skipBuild) {
    logInfo(`[build] ops-portal ${board.board_id} (pio env: ops-portal)`);
    run("pio", ["run", "-e", "ops-portal"], { cwd: appRoot });
  }

  const buildRoot = path.join(appRoot, ".pio", "build", "ops-portal");
  const srcBoot = firstExisting([
    path.join(buildRoot, "bootloader.bin"),
    path.join(webToolsRoot, "firmware", String(board.legacy_stage_dir || ""), "bootloader.bin"),
  ]);
  const srcPart = firstExisting([
    path.join(buildRoot, "partitions.bin"),
    path.join(webToolsRoot, "firmware", String(board.legacy_stage_dir || ""), "partitions.bin"),
  ]);
  const srcFw = firstExisting([
    path.join(buildRoot, "firmware.bin"),
    path.join(webToolsRoot, "firmware", String(board.legacy_stage_dir || ""), "firmware.bin"),
  ]);
  const srcApp0 = firstExisting([
    path.join(buildRoot, "boot_app0.bin"),
    path.join(webToolsRoot, "firmware", String(board.legacy_stage_dir || ""), "boot_app0.bin"),
    path.join(process.env.HOME || "", ".platformio", "packages", "framework-arduinoespressif32", "tools", "partitions", "boot_app0.bin"),
  ]);

  requireFile(srcBoot, "bootloader");
  requireFile(srcPart, "partition table");
  requireFile(srcFw, "firmware");
  if (!srcApp0) fail("boot_app0.bin not found in build output or platformio fallback path");
  requireFile(srcApp0, "boot_app0");

  const outDir = path.join(webToolsRoot, "firmware", board.board_id, version);
  fs.mkdirSync(outDir, { recursive: true });

  const outBoot = path.join(outDir, "bootloader.bin");
  const outPart = path.join(outDir, "partition-table.bin");
  const outApp0 = path.join(outDir, "boot_app0.bin");
  const outFw = path.join(outDir, "firmware.bin");
  copyFile(srcBoot, outBoot);
  copyFile(srcPart, outPart);
  copyFile(srcApp0, outApp0);
  copyFile(srcFw, outFw);

  const offsets = board.offsets || {};
  const binaries = [
    {
      name: "bootloader.bin",
      offset: Number(offsets.bootloader || 0),
      path: `firmware/${board.board_id}/${version}/bootloader.bin`,
      sha256: sha256File(outBoot),
      size_bytes: fs.statSync(outBoot).size,
    },
    {
      name: "partition-table.bin",
      offset: Number(offsets["partition-table"] || offsets.partition || 0),
      path: `firmware/${board.board_id}/${version}/partition-table.bin`,
      sha256: sha256File(outPart),
      size_bytes: fs.statSync(outPart).size,
    },
    {
      name: "boot_app0.bin",
      offset: Number(offsets.boot_app0 || 0),
      path: `firmware/${board.board_id}/${version}/boot_app0.bin`,
      sha256: sha256File(outApp0),
      size_bytes: fs.statSync(outApp0).size,
    },
    {
      name: "firmware.bin",
      offset: Number(offsets.firmware || 0),
      path: `firmware/${board.board_id}/${version}/firmware.bin`,
      sha256: sha256File(outFw),
      size_bytes: fs.statSync(outFw).size,
    },
  ];

  const buildInfo = {
    ...buildInfoBase({
      app: "ops-portal",
      boardId: board.board_id,
      version,
      repoRoot,
    }),
    control_plane_url: process.env.CONTROL_PLANE_URL || "http://192.168.8.114:8099/god",
    binaries,
  };
  writeJson(path.join(outDir, "buildinfo.json"), buildInfo);
  writeShaFile(outDir, ["bootloader.bin", "partition-table.bin", "boot_app0.bin", "firmware.bin", "buildinfo.json"]);

  const legacy = String(board.legacy_stage_dir || "");
  if (legacy) {
    const compatDir = path.join(webToolsRoot, "firmware", legacy);
    fs.mkdirSync(compatDir, { recursive: true });
    copyFile(outBoot, path.join(compatDir, "bootloader.bin"));
    copyFile(outPart, path.join(compatDir, "partitions.bin"));
    copyFile(outApp0, path.join(compatDir, "boot_app0.bin"));
    copyFile(outFw, path.join(compatDir, "firmware.bin"));
  }

  const manifest = {
    name: "SODS Ops Portal CYD",
    version,
    chipFamily: "ESP32",
    builds: [
      {
        chipFamily: "ESP32",
        parts: binaries.map((item) => ({ path: item.path, offset: item.offset })),
      },
    ],
    metadata: {
      app: "ops-portal",
      board_id: board.board_id,
      buildinfo_path: `firmware/${board.board_id}/${version}/buildinfo.json`,
      sha256sums_path: `firmware/${board.board_id}/${version}/sha256sums.txt`,
      generated_ts_ms: Date.now(),
    },
  };
  writeJson(path.join(webToolsRoot, "manifest-portal-cyd.json"), manifest);
  logInfo(`[stage] ops-portal ${board.board_id} -> ${outDir}`);
}

try {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    process.exit(0);
  }
  const boards = readBoards(repoRoot);
  const targets = selectBoards(args, SUPPORTED);
  const version = resolveVersion(args);
  for (const boardId of targets) {
    const board = boards.get(boardId);
    if (!board) fail(`board_id missing from firmware/boards.json: ${boardId}`);
    stageBoard(board, version, args.skipBuild);
  }
  if (!args.dryRun) {
    run("node", ["tools/verify.mjs", ...(args.all ? ["--all"] : ["--board", targets.join(",")]), "--version", version], { cwd: appRoot });
  }
} catch (error) {
  process.stderr.write(`${String(error?.message || error)}\n`);
  process.exit(error?.exitCode || 2);
}
