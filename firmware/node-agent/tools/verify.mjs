#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  parseArgs,
  readBoards,
  selectBoards,
  resolveVersion,
  readJson,
  requireFile,
  sha256File,
  fail,
  logInfo,
} from "../../tools/fw-common.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const appRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(appRoot, "..", "..");
const webToolsRoot = path.join(appRoot, "esp-web-tools");

const BOARD_CFG = {
  "esp32-devkitv1": { manifest: "manifest.json" },
  "esp32-c3": { manifest: "manifest-esp32c3.json" },
};

function usage() {
  logInfo("usage: node tools/verify.mjs --board <esp32-devkitv1|esp32-c3> --version <ver>");
  logInfo("   or: node tools/verify.mjs --all --version <ver>");
}

function verifyBoard(boardId, manifestName, version) {
  const manifestPath = path.join(webToolsRoot, manifestName);
  requireFile(manifestPath, "manifest");
  const manifest = readJson(manifestPath, "manifest");
  const builds = Array.isArray(manifest?.builds) ? manifest.builds : [];
  if (builds.length === 0) fail(`manifest has no builds: ${manifestPath}`);
  const parts = Array.isArray(builds[0]?.parts) ? builds[0].parts : [];
  if (parts.length === 0) fail(`manifest has no parts: ${manifestPath}`);

  const expectedPrefix = `firmware/${boardId}/${version}/`;
  for (const part of parts) {
    const rel = String(part.path || "");
    if (!rel.startsWith(expectedPrefix)) {
      fail(`manifest part path drift (${boardId}): expected prefix ${expectedPrefix}, got ${rel}`);
    }
    const abs = path.join(webToolsRoot, rel);
    requireFile(abs, `artifact (${rel})`);
  }

  const meta = manifest?.metadata || {};
  const buildInfoRel = String(meta.buildinfo_path || "");
  const shaRel = String(meta.sha256sums_path || "");
  if (!buildInfoRel || !shaRel) {
    fail(`manifest metadata missing buildinfo/sha entries: ${manifestPath}`);
  }
  const buildInfoPath = path.join(webToolsRoot, buildInfoRel);
  const shaPath = path.join(webToolsRoot, shaRel);
  requireFile(buildInfoPath, "buildinfo");
  requireFile(shaPath, "sha256sums");

  const buildInfo = readJson(buildInfoPath, "buildinfo");
  const binaries = Array.isArray(buildInfo?.binaries) ? buildInfo.binaries : [];
  if (binaries.length < 3) fail(`buildinfo missing binaries list: ${buildInfoPath}`);

  const shaLines = String(fs.readFileSync(shaPath, "utf8")).split(/\r?\n/).filter(Boolean);
  const shaMap = new Map();
  for (const line of shaLines) {
    const partsLine = line.trim().split(/\s+/);
    if (partsLine.length < 2) continue;
    shaMap.set(partsLine[partsLine.length - 1], partsLine[0]);
  }

  for (const binary of binaries) {
    const rel = String(binary.path || "");
    const name = String(binary.name || "");
    if (!rel || !name) fail(`invalid binary entry in buildinfo: ${buildInfoPath}`);
    const abs = path.join(webToolsRoot, rel);
    requireFile(abs, `buildinfo artifact (${rel})`);
    const digest = sha256File(abs);
    if (digest !== String(binary.sha256 || "")) {
      fail(`sha mismatch for ${rel}: buildinfo=${binary.sha256} actual=${digest}`);
    }
    const shaName = shaMap.get(name);
    if (!shaName) fail(`sha256sums missing ${name} in ${shaPath}`);
    if (shaName !== digest) fail(`sha256sums mismatch for ${name}: listed=${shaName} actual=${digest}`);
  }

  logInfo(`[verify] node-agent ${boardId} OK`);
}

try {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    process.exit(0);
  }
  const _boards = readBoards(repoRoot);
  const supported = Object.keys(BOARD_CFG);
  const targets = selectBoards(args, supported);
  const version = resolveVersion(args);
  for (const boardId of targets) {
    verifyBoard(boardId, BOARD_CFG[boardId].manifest, version);
  }
} catch (error) {
  process.stderr.write(`${String(error?.message || error)}\n`);
  process.exit(error?.exitCode || 2);
}
