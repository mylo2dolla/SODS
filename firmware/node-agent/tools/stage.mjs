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

const BOARD_CFG = {
  "esp32-devkitv1": {
    env: "esp32dev",
    chipFamily: "ESP32",
    manifest: "manifest.json",
    src: {
      bootloader: ".pio/build/esp32dev/bootloader.bin",
      partition: ".pio/build/esp32dev/partitions.bin",
      firmware: ".pio/build/esp32dev/firmware.bin",
    },
  },
  "esp32-c3": {
    env: "esp32c3",
    chipFamily: "ESP32-C3",
    manifest: "manifest-esp32c3.json",
    src: {
      bootloader: ".pio/build/esp32c3/bootloader.bin",
      partition: ".pio/build/esp32c3/partitions.bin",
      firmware: ".pio/build/esp32c3/firmware.bin",
    },
  },
};

function usage() {
  logInfo("usage: node tools/stage.mjs --board <esp32-devkitv1|esp32-c3> --version <ver>");
  logInfo("   or: node tools/stage.mjs --all --version <ver>");
  logInfo("flags: --skip-build");
}

function stageBoard(board, boardCfg, version, skipBuild) {
  if (!skipBuild) {
    logInfo(`[build] node-agent ${board.board_id} (pio env: ${boardCfg.env})`);
    run("pio", ["run", "-e", boardCfg.env], { cwd: appRoot });
  }

  const srcBoot = firstExisting([
    path.join(appRoot, boardCfg.src.bootloader),
    path.join(webToolsRoot, "firmware", String(board.legacy_stage_dir || ""), "bootloader.bin"),
  ]);
  const srcPart = firstExisting([
    path.join(appRoot, boardCfg.src.partition),
    path.join(webToolsRoot, "firmware", String(board.legacy_stage_dir || ""), "partitions.bin"),
  ]);
  const srcFw = firstExisting([
    path.join(appRoot, boardCfg.src.firmware),
    path.join(webToolsRoot, "firmware", String(board.legacy_stage_dir || ""), "firmware.bin"),
  ]);
  requireFile(srcBoot, "bootloader");
  requireFile(srcPart, "partition table");
  requireFile(srcFw, "firmware");

  const outDir = path.join(webToolsRoot, "firmware", board.board_id, version);
  fs.mkdirSync(outDir, { recursive: true });

  const outBoot = path.join(outDir, "bootloader.bin");
  const outPart = path.join(outDir, "partition-table.bin");
  const outFw = path.join(outDir, "firmware.bin");
  copyFile(srcBoot, outBoot);
  copyFile(srcPart, outPart);
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
      offset: Number(offsets["partition-table"] || offsets.partition_table || offsets.partition || 0),
      path: `firmware/${board.board_id}/${version}/partition-table.bin`,
      sha256: sha256File(outPart),
      size_bytes: fs.statSync(outPart).size,
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
      app: "node-agent",
      boardId: board.board_id,
      version,
      repoRoot,
    }),
    control_plane_url: process.env.CONTROL_PLANE_URL || "http://192.168.8.114:8099/god",
    binaries,
  };
  const buildInfoPath = path.join(outDir, "buildinfo.json");
  writeJson(buildInfoPath, buildInfo);
  writeShaFile(outDir, ["bootloader.bin", "partition-table.bin", "firmware.bin", "buildinfo.json"]);

  const legacy = String(board.legacy_stage_dir || "");
  if (legacy) {
    const compatDir = path.join(webToolsRoot, "firmware", legacy);
    fs.mkdirSync(compatDir, { recursive: true });
    copyFile(outBoot, path.join(compatDir, "bootloader.bin"));
    copyFile(outPart, path.join(compatDir, "partitions.bin"));
    copyFile(outFw, path.join(compatDir, "firmware.bin"));
  }

  const manifest = {
    name: `SODS Node Agent (${boardCfg.chipFamily})`,
    version,
    chipFamily: boardCfg.chipFamily,
    new_install_prompt_erase: true,
    builds: [
      {
        chipFamily: boardCfg.chipFamily,
        parts: binaries.map((item) => ({ path: item.path, offset: item.offset })),
      },
    ],
    metadata: {
      app: "node-agent",
      board_id: board.board_id,
      buildinfo_path: `firmware/${board.board_id}/${version}/buildinfo.json`,
      sha256sums_path: `firmware/${board.board_id}/${version}/sha256sums.txt`,
      generated_ts_ms: Date.now(),
    },
  };
  writeJson(path.join(webToolsRoot, boardCfg.manifest), manifest);

  logInfo(`[stage] node-agent ${board.board_id} -> ${outDir}`);
}

try {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    process.exit(0);
  }
  const version = resolveVersion(args);
  const boards = readBoards(repoRoot);
  const supported = Object.keys(BOARD_CFG);
  const targets = selectBoards(args, supported);

  for (const boardId of targets) {
    const board = boards.get(boardId);
    if (!board) fail(`board_id missing from firmware/boards.json: ${boardId}`);
    stageBoard(board, BOARD_CFG[boardId], version, args.skipBuild);
  }

  if (!args.dryRun) {
    run("node", ["tools/verify.mjs", ...(args.all ? ["--all"] : ["--board", targets.join(",")]), "--version", version], { cwd: appRoot });
  }
} catch (error) {
  process.stderr.write(`${String(error?.message || error)}\n`);
  process.exit(error?.exitCode || 2);
}
