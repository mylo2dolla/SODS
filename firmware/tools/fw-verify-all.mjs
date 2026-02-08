#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";
import { run, fail, logInfo, readJson } from "./fw-common.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const firmwareRoot = path.resolve(__dirname, "..");

function readBoards() {
  const boardsPath = path.join(firmwareRoot, "boards.json");
  const data = readJson(boardsPath, "boards.json");
  const out = new Map();
  const rows = Array.isArray(data?.boards) ? data.boards : [];
  for (const board of rows) {
    const id = String(board?.board_id || "");
    if (id) out.set(id, board);
  }
  if (out.size === 0) fail(`no boards loaded from ${boardsPath}`);
  return out;
}

function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  hash.update(fs.readFileSync(filePath));
  return hash.digest("hex");
}

function extractVersionFromManifest(manifestPath) {
  if (!fs.existsSync(manifestPath)) fail(`manifest missing: ${manifestPath}`);
  const manifest = readJson(manifestPath, "manifest");
  const buildInfoPath = String(manifest?.metadata?.buildinfo_path || "");
  if (!buildInfoPath) fail(`manifest missing metadata.buildinfo_path: ${manifestPath}`);
  const parts = buildInfoPath.split("/");
  // firmware/<board>/<version>/buildinfo.json
  if (parts.length < 4) fail(`cannot extract version from buildinfo path: ${buildInfoPath}`);
  return parts[2];
}

function offsetKeyFromPartPath(partPath) {
  const name = path.basename(String(partPath || ""));
  if (name === "bootloader.bin") return "bootloader";
  if (name === "partition-table.bin") return "partition-table";
  if (name === "boot_app0.bin") return "boot_app0";
  if (name === "firmware.bin") return "firmware";
  return "";
}

function legacyNameForVersionedFile(fileName) {
  if (fileName === "partition-table.bin") return "partitions.bin";
  return fileName;
}

function verifyManifestConsistency(appName, appRoot, boardId, manifestName, expectedVersion, boards) {
  const manifestPath = path.join(appRoot, "esp-web-tools", manifestName);
  const manifest = readJson(manifestPath, "manifest");
  const board = boards.get(boardId);
  if (!board) fail(`[${appName}] board missing from boards.json: ${boardId}`);

  const builds = Array.isArray(manifest?.builds) ? manifest.builds : [];
  if (builds.length === 0) fail(`[${appName}] manifest has no builds: ${manifestPath}`);
  const manifestVersion = String(manifest?.version || "");
  if (manifestVersion !== expectedVersion) {
    fail(`[${appName}] manifest version mismatch (${manifestName}=${manifestVersion}, expected=${expectedVersion})`);
  }

  const parts = Array.isArray(builds[0]?.parts) ? builds[0].parts : [];
  if (parts.length === 0) fail(`[${appName}] manifest has no parts: ${manifestPath}`);

  for (const part of parts) {
    const rel = String(part?.path || "");
    if (!rel.startsWith(`firmware/${boardId}/${expectedVersion}/`)) {
      fail(`[${appName}] manifest part path drift: ${rel}`);
    }
    const abs = path.join(appRoot, "esp-web-tools", rel);
    if (!fs.existsSync(abs)) {
      fail(`[${appName}] missing versioned artifact: ${abs}`);
    }
    const offsetKey = offsetKeyFromPartPath(rel);
    if (!offsetKey) continue;
    const offsets = board.offsets || {};
    const expectedOffset = Number(offsets[offsetKey] ?? offsets.partition ?? 0);
    const actualOffset = Number(part?.offset ?? 0);
    if (expectedOffset !== actualOffset) {
      fail(`[${appName}] offset drift for ${rel}: manifest=${actualOffset} boards.json=${expectedOffset}`);
    }

    const legacyDir = String(board.legacy_stage_dir || "");
    if (!legacyDir) continue;
    const legacyFile = path.join(appRoot, "esp-web-tools", "firmware", legacyDir, legacyNameForVersionedFile(path.basename(rel)));
    if (!fs.existsSync(legacyFile)) {
      fail(`[${appName}] missing legacy compatibility artifact: ${legacyFile}`);
    }
    const shaVersioned = sha256File(abs);
    const shaLegacy = sha256File(legacyFile);
    if (shaVersioned !== shaLegacy) {
      fail(`[${appName}] legacy artifact drift for ${legacyFile}`);
    }
  }
}

try {
  const boards = readBoards();

  logInfo("[fw:verify] node-agent");
  const nodeBase = path.join(firmwareRoot, "node-agent");
  const vEsp32 = extractVersionFromManifest(path.join(nodeBase, "esp-web-tools", "manifest.json"));
  const vC3 = extractVersionFromManifest(path.join(nodeBase, "esp-web-tools", "manifest-esp32c3.json"));
  if (vEsp32 !== vC3) {
    fail(`node-agent manifest versions differ (esp32=${vEsp32}, c3=${vC3}); restage both together`);
  }
  verifyManifestConsistency("node-agent", nodeBase, "esp32-devkitv1", "manifest.json", vEsp32, boards);
  verifyManifestConsistency("node-agent", nodeBase, "esp32-c3", "manifest-esp32c3.json", vC3, boards);
  run("node", ["tools/verify.mjs", "--all", "--version", vEsp32], { cwd: nodeBase });

  logInfo("[fw:verify] ops-portal");
  const portalBase = path.join(firmwareRoot, "ops-portal");
  const vPortal = extractVersionFromManifest(path.join(portalBase, "esp-web-tools", "manifest-portal-cyd.json"));
  verifyManifestConsistency("ops-portal", portalBase, "cyd-2432s028", "manifest-portal-cyd.json", vPortal, boards);
  run("node", ["tools/verify.mjs", "--all", "--version", vPortal], { cwd: portalBase });

  logInfo("[fw:verify] sods-p4-godbutton");
  const p4Base = path.join(firmwareRoot, "sods-p4-godbutton");
  const vP4 = extractVersionFromManifest(path.join(p4Base, "esp-web-tools", "manifest-p4.json"));
  verifyManifestConsistency("sods-p4-godbutton", p4Base, "waveshare-esp32p4", "manifest-p4.json", vP4, boards);
  run("node", ["tools/verify.mjs", "--all", "--version", vP4], { cwd: p4Base });

  logInfo("[fw:verify] PASS");
} catch (error) {
  process.stderr.write(`${String(error?.message || error)}\n`);
  process.exit(error?.exitCode || 2);
}
