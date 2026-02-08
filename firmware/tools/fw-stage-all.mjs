#!/usr/bin/env node
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs, resolveVersion, run, logInfo } from "./fw-common.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const firmwareRoot = path.resolve(__dirname, "..");

try {
  const args = parseArgs(process.argv.slice(2));
  const version = resolveVersion(args);
  const flags = ["--all", "--version", version];
  if (args.skipBuild) flags.push("--skip-build");

  logInfo(`[fw:stage] version=${version}`);
  run("node", ["tools/stage.mjs", ...flags], { cwd: path.join(firmwareRoot, "node-agent") });
  run("node", ["tools/stage.mjs", ...flags], { cwd: path.join(firmwareRoot, "ops-portal") });
  run("node", ["tools/stage.mjs", ...flags], { cwd: path.join(firmwareRoot, "sods-p4-godbutton") });
  run("node", ["tools/fw-verify-all.mjs"], { cwd: firmwareRoot });
  logInfo("[fw:stage] PASS");
} catch (error) {
  process.stderr.write(`${String(error?.message || error)}\n`);
  process.exit(error?.exitCode || 2);
}
