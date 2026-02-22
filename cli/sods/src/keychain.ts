import { spawnSync } from "node:child_process";

import { normalizeKnowledgeEntityKey, type KnowledgeSecretField } from "./knowledge.js";

export function knowledgeKeychainService() {
  return process.env.SODS_KNOWLEDGE_KEYCHAIN_SERVICE?.trim() || "com.lvlupkit.shared-knowledge.v1";
}

export function knowledgeKeychainAccount(entityKey: string, secretName: KnowledgeSecretField) {
  const normalized = normalizeKnowledgeEntityKey(entityKey);
  return `knowledge::${normalized}::${secretName}`;
}

export function getKeychainSecret(entityKey: string, secretName: KnowledgeSecretField): string | null {
  const service = knowledgeKeychainService();
  const account = knowledgeKeychainAccount(entityKey, secretName);
  const run = spawnSync("security", ["find-generic-password", "-s", service, "-a", account, "-w"], {
    encoding: "utf8",
  });

  if (run.status === 0) {
    const value = String(run.stdout ?? "").trim();
    return value || null;
  }

  const stderr = String(run.stderr ?? "");
  if (/could not be found/i.test(stderr) || /item not found/i.test(stderr)) {
    return null;
  }

  throw new Error(stderr.trim() || `security find-generic-password failed (${run.status ?? -1})`);
}

export function setKeychainSecret(entityKey: string, secretName: KnowledgeSecretField, value: string) {
  const service = knowledgeKeychainService();
  const account = knowledgeKeychainAccount(entityKey, secretName);
  const trimmed = String(value ?? "").trim();

  if (!trimmed) {
    deleteKeychainSecret(entityKey, secretName);
    return;
  }

  const run = spawnSync("security", ["add-generic-password", "-U", "-s", service, "-a", account, "-w", trimmed], {
    encoding: "utf8",
  });

  if (run.status === 0) {
    return;
  }

  throw new Error(String(run.stderr ?? "").trim() || `security add-generic-password failed (${run.status ?? -1})`);
}

export function deleteKeychainSecret(entityKey: string, secretName: KnowledgeSecretField) {
  const service = knowledgeKeychainService();
  const account = knowledgeKeychainAccount(entityKey, secretName);
  const run = spawnSync("security", ["delete-generic-password", "-s", service, "-a", account], {
    encoding: "utf8",
  });

  if (run.status === 0) {
    return;
  }

  const stderr = String(run.stderr ?? "");
  if (/could not be found/i.test(stderr) || /item not found/i.test(stderr)) {
    return;
  }

  throw new Error(stderr.trim() || `security delete-generic-password failed (${run.status ?? -1})`);
}
