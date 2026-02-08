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
  copyFile,
  firstExisting,
  requireFile,
  sha256File,
  writeShaFile,
  writeJson,
  buildInfoBase,
  chooseEsptool,
  tryEsptool,
  fail,
  logInfo,
} from "../../tools/fw-common.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const appRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(appRoot, "..", "..");
const webToolsRoot = path.join(appRoot, "esp-web-tools");
const SUPPORTED = ["waveshare-esp32p4"];

function usage() {
  logInfo("usage: node tools/stage.mjs --board waveshare-esp32p4 --version <ver>");
  logInfo("   or: node tools/stage.mjs --all --version <ver>");
  logInfo("flags: --skip-build");
}

function requireP4Image(esptool, filePath, label) {
  const out = tryEsptool(esptool, ["image-info", filePath]);
  if (out.status !== 0) {
    fail(`${label} image-info failed: ${String(out.stderr || out.stdout || "").trim()}`);
  }
  const text = `${String(out.stdout || "")}\n${String(out.stderr || "")}`.toLowerCase();
  if (!text.includes("esp32-p4") && !text.includes("chip id: 18")) {
    fail(`${label} is not an ESP32-P4 image: ${filePath}`);
  }
}

function stageBoard(board, version, skipBuild) {
  const doBuild = () => {
    logInfo(`[build] sods-p4-godbutton ${board.board_id} (idf.py set-target esp32p4 + build)`);
    run("idf.py", ["set-target", "esp32p4"], { cwd: appRoot });
    run("idf.py", ["build"], { cwd: appRoot });
  };

  if (!skipBuild) {
    doBuild();
  }

  let srcBoot = firstExisting([path.join(appRoot, "build", "bootloader", "bootloader.bin")]);
  let srcPart = firstExisting([path.join(appRoot, "build", "partition_table", "partition-table.bin")]);
  let srcFw = firstExisting([path.join(appRoot, "build", "sods-p4-godbutton.bin")]);

  if (skipBuild && (!srcBoot || !srcPart || !srcFw)) {
    logInfo("[stage] build artifacts missing under build/, attempting recovery build");
    try {
      doBuild();
    } catch {
      fail("P4 build artifacts missing and idf.py build failed. Source ESP-IDF export, then run tools/p4-build.sh and retry.");
    }
    srcBoot = firstExisting([path.join(appRoot, "build", "bootloader", "bootloader.bin")]);
    srcPart = firstExisting([path.join(appRoot, "build", "partition_table", "partition-table.bin")]);
    srcFw = firstExisting([path.join(appRoot, "build", "sods-p4-godbutton.bin")]);
  }

  requireFile(srcBoot, "bootloader");
  requireFile(srcPart, "partition table");
  requireFile(srcFw, "firmware");
  const esptool = chooseEsptool();
  requireP4Image(esptool, srcBoot, "bootloader");
  requireP4Image(esptool, srcFw, "firmware");

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
      offset: Number(offsets["partition-table"] || offsets.partition || 0),
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
      app: "sods-p4-godbutton",
      boardId: board.board_id,
      version,
      repoRoot,
    }),
    control_plane_url: process.env.CONTROL_PLANE_URL || "http://192.168.8.114:8099/god",
    binaries,
  };
  writeJson(path.join(outDir, "buildinfo.json"), buildInfo);
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
    name: "SODS P4 God Button",
    version,
    chipFamily: "ESP32-P4",
    new_install_prompt_erase: true,
    builds: [
      {
        chipFamily: "ESP32-P4",
        parts: binaries.map((item) => ({ path: item.path, offset: item.offset })),
      },
    ],
    metadata: {
      app: "sods-p4-godbutton",
      board_id: board.board_id,
      buildinfo_path: `firmware/${board.board_id}/${version}/buildinfo.json`,
      sha256sums_path: `firmware/${board.board_id}/${version}/sha256sums.txt`,
      generated_ts_ms: Date.now(),
    },
  };
  writeJson(path.join(webToolsRoot, "manifest-p4.json"), manifest);
  logInfo(`[stage] sods-p4-godbutton ${board.board_id} -> ${outDir}`);
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
