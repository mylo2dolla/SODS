#!/usr/bin/env node
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs, readBoards, selectBoards, run, fail, logInfo } from "../../tools/fw-common.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const appRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(appRoot, "..", "..");
const SUPPORTED = ["cyd-2432s028"];

function usage() {
  logInfo("usage: node tools/build.mjs --board cyd-2432s028 | --all");
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
    const envs = ["ops-portal", "ops-portal-rstminus1", "ops-portal-st7789"];
    for (const envName of envs) {
      logInfo(`[build] ops-portal ${boardId} (pio env: ${envName})`);
      run("pio", ["run", "-e", envName], { cwd: appRoot });
    }
  }
} catch (error) {
  process.stderr.write(`${String(error?.message || error)}\n`);
  process.exit(error?.exitCode || 2);
}
