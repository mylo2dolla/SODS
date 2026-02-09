import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { BLEIdentityRegistry, maskManufacturer, normalizeName } from "./identity-core.mjs";

function tempDbPath() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ble-registry-test-"));
  return path.join(dir, "registry.sqlite");
}

test("normalizeName strips dynamic BLE suffixes", () => {
  assert.equal(normalizeName("Apple Watch (3)"), "apple watch");
  assert.equal(normalizeName("Sensor-0A1B"), "sensor");
  assert.equal(normalizeName("  Node    77ff  "), "node");
});

test("maskManufacturer keeps known stable bytes and masks volatile bytes", () => {
  const apple = maskManufacturer(0x004c, "4c001005112233445566778899aabbcc");
  assert.equal(apple.mfg_masked, "4c001005112200000000000000000000");
  assert.equal(apple.mfg_mask.length, 16);

  const generic = maskManufacturer(0x9999, "a1b2c3d4e5f6");
  assert.equal(generic.mfg_masked, "a1b2c3d40000");
});

test("stable observations keep same device_id and conflicting observations split", () => {
  const registry = new BLEIdentityRegistry({ dbPath: tempDbPath(), reset: true });

  const first = registry.processObservation({
    ts_ms: 1_000,
    scanner_id: "exec-pi-aux",
    addr: "aa:bb:cc:dd:ee:01",
    addr_type: "random",
    services: ["180f", "180a"],
    name: "watch-9f0a",
    mfg_company_id: 76,
    mfg_data_raw: "4c001005112233445566778899aabbcc",
    rssi: -58,
  });

  const second = registry.processObservation({
    ts_ms: 2_500,
    scanner_id: "exec-mac-1",
    addr: "aa:bb:cc:dd:ee:02",
    addr_type: "random",
    services: ["180a", "180f"],
    name: "watch-01bc",
    mfg_company_id: 76,
    mfg_data_raw: "4c0010051122ddccbbaa009988776655",
    rssi: -61,
  });

  assert.equal(first.device_id, second.device_id);
  assert.ok(second.score === null || second.score >= 70);

  const third = registry.processObservation({
    ts_ms: 3_000,
    scanner_id: "exec-pi-aux",
    addr: "11:22:33:44:55:66",
    addr_type: "public",
    services: ["1812"],
    name: "other-device",
    mfg_company_id: 6,
    mfg_data_raw: "0006aabbccdd",
    rssi: -44,
  });

  assert.notEqual(first.device_id, third.device_id);
});
