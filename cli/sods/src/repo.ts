import { existsSync } from "node:fs";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";

export function findRepoRoot(fromUrl: string) {
  let dir = resolve(fileURLToPath(new URL(".", fromUrl)));
  for (let i = 0; i < 8; i += 1) {
    const toolsPath = join(dir, "tools", "_sods_cli.sh");
    const cliPath = join(dir, "cli", "sods");
    if (existsSync(toolsPath) && existsSync(cliPath)) return dir;
    const parent = resolve(dir, "..");
    if (parent === dir) break;
    dir = parent;
  }
  return resolve(fileURLToPath(new URL("../../../..", fromUrl)));
}
