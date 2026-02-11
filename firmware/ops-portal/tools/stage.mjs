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
const VARIANTS = [
  { id: "ili9341", label: "ILI9341 (RST=4)", pioEnv: "ops-portal", dirPrefix: "" },
  { id: "ili9341-rstminus1", label: "ILI9341 (RST=-1)", pioEnv: "ops-portal-rstminus1", dirPrefix: "_" },
  { id: "st7789", label: "ST7789", pioEnv: "ops-portal-st7789", dirPrefix: "_" },
  { id: "sunton-hspi", label: "ILI9341 (Sunton HSPI 14/12/13/15)", pioEnv: "ops-portal-sunton-hspi", dirPrefix: "_" },
];

function sleepSync(ms) {
  // Node doesn't have a built-in synchronous sleep; Atomics.wait is the least-bad option here.
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function waitForStableFile(filePath, { minBytes = 1, attempts = 12, delayMs = 25 } = {}) {
  // On some systems/APFS clone paths, copied artifacts can transiently appear as 0 bytes.
  // Verify/stage integrity relies on hashing stable content.
  let lastSize = -1;
  for (let i = 0; i < attempts; i++) {
    const size = fs.statSync(filePath).size;
    if (size >= minBytes && size === lastSize) return;
    lastSize = size;
    sleepSync(delayMs);
  }
}

function usage() {
  logInfo("usage: node tools/stage.mjs --board cyd-2432s028 --version <ver>");
  logInfo("   or: node tools/stage.mjs --all --version <ver>");
  logInfo("flags: --skip-build");
}

function stageBoard(board, version, skipBuild) {
  const builds = [];
  const offsets = board.offsets || {};

  for (const variant of VARIANTS) {
    const variantDirName = `${variant.dirPrefix}${version}${variant.dirPrefix ? "-" + variant.id : ""}`;

    if (!skipBuild) {
      logInfo(`[build] ops-portal ${board.board_id} (pio env: ${variant.pioEnv})`);
      run("pio", ["run", "-e", variant.pioEnv], { cwd: appRoot });
    }

    const buildRoot = path.join(appRoot, ".pio", "build", variant.pioEnv);
    const srcBoot = firstExisting([path.join(buildRoot, "bootloader.bin")]);
    const srcPart = firstExisting([path.join(buildRoot, "partitions.bin")]);
    const srcFw = firstExisting([path.join(buildRoot, "firmware.bin")]);
    const srcApp0 = firstExisting([
      path.join(buildRoot, "boot_app0.bin"),
      path.join(process.env.HOME || "", ".platformio", "packages", "framework-arduinoespressif32", "tools", "partitions", "boot_app0.bin"),
    ]);

    requireFile(srcBoot, "bootloader");
    requireFile(srcPart, "partition table");
    requireFile(srcFw, "firmware");
    if (!srcApp0) fail("boot_app0.bin not found in build output or platformio fallback path");
    requireFile(srcApp0, "boot_app0");

    const outDir = path.join(webToolsRoot, "firmware", board.board_id, variantDirName);
    fs.mkdirSync(outDir, { recursive: true });

    const outBoot = path.join(outDir, "bootloader.bin");
    const outPart = path.join(outDir, "partition-table.bin");
    const outApp0 = path.join(outDir, "boot_app0.bin");
    const outFw = path.join(outDir, "firmware.bin");
    copyFile(srcBoot, outBoot);
    copyFile(srcPart, outPart);
    copyFile(srcApp0, outApp0);
    copyFile(srcFw, outFw);

    waitForStableFile(outBoot);
    waitForStableFile(outPart);
    waitForStableFile(outApp0);
    waitForStableFile(outFw);

    const binaries = [
      {
        name: "bootloader.bin",
        offset: Number(offsets.bootloader || 0),
        path: `firmware/${board.board_id}/${variantDirName}/bootloader.bin`,
        sha256: sha256File(outBoot),
        size_bytes: fs.statSync(outBoot).size,
      },
      {
        name: "partition-table.bin",
        offset: Number(offsets["partition-table"] || offsets.partition || 0),
        path: `firmware/${board.board_id}/${variantDirName}/partition-table.bin`,
        sha256: sha256File(outPart),
        size_bytes: fs.statSync(outPart).size,
      },
      {
        name: "boot_app0.bin",
        offset: Number(offsets.boot_app0 || 0),
        path: `firmware/${board.board_id}/${variantDirName}/boot_app0.bin`,
        sha256: sha256File(outApp0),
        size_bytes: fs.statSync(outApp0).size,
      },
      {
        name: "firmware.bin",
        offset: Number(offsets.firmware || 0),
        path: `firmware/${board.board_id}/${variantDirName}/firmware.bin`,
        sha256: sha256File(outFw),
        size_bytes: fs.statSync(outFw).size,
      },
    ];

    const buildInfo = {
      ...buildInfoBase({
        app: "ops-portal",
        boardId: board.board_id,
        version: variantDirName,
        repoRoot,
      }),
      variant: variant.id,
      variant_label: variant.label,
      control_plane_url: process.env.CONTROL_PLANE_URL || "http://192.168.8.114:8099/god",
      binaries,
    };
    writeJson(path.join(outDir, "buildinfo.json"), buildInfo);
    writeShaFile(outDir, ["bootloader.bin", "partition-table.bin", "boot_app0.bin", "firmware.bin", "buildinfo.json"]);

    builds.push({
      chipFamily: "ESP32",
      name: `CYD ${variant.label}`,
      parts: binaries.map((item) => ({ path: item.path, offset: item.offset })),
    });

    logInfo(`[stage] ops-portal ${board.board_id} variant=${variant.id} -> ${outDir}`);
  }

  const legacy = String(board.legacy_stage_dir || "");
  if (legacy) {
    // Maintain legacy compatibility directory (single-build) with the default variant.
    const compatDir = path.join(webToolsRoot, "firmware", legacy);
    fs.mkdirSync(compatDir, { recursive: true });
    const defaultDir = path.join(webToolsRoot, "firmware", board.board_id, version);
    copyFile(path.join(defaultDir, "bootloader.bin"), path.join(compatDir, "bootloader.bin"));
    copyFile(path.join(defaultDir, "partition-table.bin"), path.join(compatDir, "partitions.bin"));
    copyFile(path.join(defaultDir, "boot_app0.bin"), path.join(compatDir, "boot_app0.bin"));
    copyFile(path.join(defaultDir, "firmware.bin"), path.join(compatDir, "firmware.bin"));
  }

  const manifest = {
    name: "SODS Ops Portal CYD",
    version,
    chipFamily: "ESP32",
    builds,
    metadata: {
      app: "ops-portal",
      board_id: board.board_id,
      buildinfo_path: `firmware/${board.board_id}/${version}/buildinfo.json`,
      default_variant_version: version,
      generated_ts_ms: Date.now(),
    },
  };
  writeJson(path.join(webToolsRoot, "manifest-portal-cyd.json"), manifest);
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
