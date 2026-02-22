import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const cliDir = path.resolve(__dirname, "..");

test("sods help prints canonical default endpoints", () => {
  const env = {
    ...process.env,
    PI_LOGGER_URL: "",
    PI_LOGGER: "",
    AUX_HOST: "pi-aux.local",
    LOGGER_HOST: "pi-logger.local",
    SODS_PORT: "9123",
    SODS_STATION_URL: "",
    SODS_BASE_URL: "",
    SODS_STATION: "",
    STATION_URL: "",
  };

  const run = spawnSync(process.execPath, ["dist/cli.js", "help"], {
    cwd: cliDir,
    env,
    encoding: "utf8",
  });

  assert.equal(run.status, 0, run.stderr || run.stdout);
  assert.match(run.stdout, /--pi-logger http:\/\/pi-aux\.local:9101/);
  assert.match(run.stdout, /--port 9123/);
  assert.match(run.stdout, /--station http:\/\/localhost:9123/);
  assert.match(run.stdout, /--logger http:\/\/pi-aux\.local:9101/);
  assert.match(run.stdout, /pi-logger: PI_LOGGER_URL \| PI_LOGGER, else http:\/\/pi-aux\.local:9101/);
  assert.match(run.stdout, /station: SODS_STATION_URL \| SODS_BASE_URL \| SODS_STATION \| STATION_URL, else http:\/\/localhost:9123/);
});
