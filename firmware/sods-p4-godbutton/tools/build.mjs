#!/usr/bin/env node
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs, readBoards, selectBoards, run, fail, logInfo } from "../../tools/fw-common.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const appRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(appRoot, "..", "..");
const SUPPORTED = ["waveshare-esp32p4"];

function usage() {
  logInfo("usage: node tools/build.mjs --board waveshare-esp32p4 | --all");
}

try {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    process.exit(0);
  }
  const boards = readBoards(repoRoot);
  const targets = selectBoards(args, SUPPORTED);
  for (const boardId of targets) {
    if (!boards.has(boardId)) fail(`board_id missing from firmware/boards.json: ${boardId}`);
    logInfo(`[build] sods-p4-godbutton ${boardId} (idf.py set-target esp32p4 + build)`);
    run("idf.py", ["set-target", "esp32p4"], { cwd: appRoot });
    run("idf.py", ["build"], { cwd: appRoot });
  }
} catch (error) {
  process.stderr.write(`${String(error?.message || error)}\n`);
  process.exit(error?.exitCode || 2);
}
