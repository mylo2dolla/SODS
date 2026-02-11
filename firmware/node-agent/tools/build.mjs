#!/usr/bin/env node
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs, readBoards, selectBoards, run, fail, logInfo } from "../../tools/fw-common.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const appRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(appRoot, "..", "..");

const BOARD_BUILD = {
  "esp32-devkitv1": { env: "esp32dev" },
  "esp32-c3": { env: "esp32c3" },
};

function usage() {
  logInfo("usage: node tools/build.mjs --board <esp32-devkitv1|esp32-c3> | --all");
}

try {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    process.exit(0);
  }
  const boards = readBoards(repoRoot);
  const supported = Object.keys(BOARD_BUILD);
  const targets = selectBoards(args, supported);

  for (const boardId of targets) {
    if (!boards.has(boardId)) fail(`board_id not present in firmware/boards.json: ${boardId}`);
    const env = BOARD_BUILD[boardId].env;
    logInfo(`[build] node-agent ${boardId} (pio env: ${env})`);
    run("pio", ["run", "-e", env], { cwd: appRoot });
  }
} catch (error) {
  process.stderr.write(`${String(error?.message || error)}\n`);
  process.exit(error?.exitCode || 2);
}
