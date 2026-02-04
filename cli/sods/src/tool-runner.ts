import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { performance } from "node:perf_hooks";
import { ToolEntry, ToolRunnerType, toolRegistryPaths } from "./tool-registry.js";

export type RunPayload = {
  name: string;
  input?: Record<string, unknown>;
  preset_id?: string;
  dry_run?: boolean;
};

export type RunResult = {
  ok: boolean;
  name: string;
  exit_code: number;
  duration_ms: number;
  stdout: string;
  stderr: string;
  result_json?: Record<string, unknown>;
  urls?: string[];
};

const URL_REGEX = /(https?:\/\/[^\s"'<>]+)/g;

function extractUrls(text: string) {
  const urls = new Set<string>();
  let match: RegExpExecArray | null;
  while ((match = URL_REGEX.exec(text)) !== null) {
    urls.add(match[1]);
  }
  return Array.from(urls);
}

function parseJson(text: string) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function resolveCwd(tool: ToolEntry) {
  const { repoRoot } = toolRegistryPaths();
  if (!tool.cwd || tool.cwd === "${REPO_ROOT}") return repoRoot;
  return tool.cwd;
}

function runnerCommand(runner: ToolRunnerType, scriptPath: string) {
  if (runner === "python") return { cmd: "python3", args: [scriptPath] };
  if (runner === "node") return { cmd: "node", args: [scriptPath] };
  return { cmd: "/bin/bash", args: [scriptPath] };
}

function makeTempScript(runner: ToolRunnerType, content: string) {
  const dir = mkdtempSync(join(tmpdir(), "sods-scratch-"));
  const ext = runner === "python" ? "py" : runner === "node" ? "mjs" : "sh";
  const path = join(dir, `scratch.${ext}`);
  writeFileSync(path, content, "utf8");
  return { dir, path };
}

export async function runScriptTool(tool: ToolEntry, input: Record<string, unknown>): Promise<RunResult> {
  const start = performance.now();
  if (!tool.entry) {
    return {
      ok: false,
      name: tool.name,
      exit_code: 1,
      duration_ms: 0,
      stdout: "",
      stderr: "tool entry not defined",
    };
  }
  const { repoRoot } = toolRegistryPaths();
  const scriptPath = tool.entry.startsWith("/")
    ? tool.entry
    : resolve(join(repoRoot, tool.entry));
  const timeout = Number.isFinite(tool.timeout_ms) ? (tool.timeout_ms ?? 0) : 0;
  const cwd = resolveCwd(tool);
  const env = { ...process.env, SODS_INPUT: JSON.stringify(input ?? {}), SODS_REPO_ROOT: repoRoot };
  const { cmd, args } = runnerCommand(tool.runner, scriptPath);
  return await runProcess(cmd, args, env, cwd, tool.name, timeout, start);
}

export async function runScratch(runner: ToolRunnerType, content: string, input: Record<string, unknown>): Promise<RunResult> {
  const start = performance.now();
  const { dir, path } = makeTempScript(runner, content);
  const { repoRoot } = toolRegistryPaths();
  const timeout = 0;
  const cwd = repoRoot;
  const env = { ...process.env, SODS_INPUT: JSON.stringify(input ?? {}), SODS_REPO_ROOT: repoRoot };
  const { cmd, args } = runnerCommand(runner, path);
  try {
    return await runProcess(cmd, args, env, cwd, "scratch", timeout, start);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function runProcess(
  cmd: string,
  args: string[],
  env: Record<string, string | undefined>,
  cwd: string,
  name: string,
  timeout: number,
  start: number
): Promise<RunResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { cwd, env });
    let stdout = "";
    let stderr = "";
    const timer = timeout > 0 ? setTimeout(() => {
      child.kill("SIGKILL");
    }, timeout) : null;
    child.stdout.on("data", (d) => (stdout += d.toString()));
    child.stderr.on("data", (d) => (stderr += d.toString()));
    child.on("error", (e) => {
      if (timer) clearTimeout(timer);
      reject(e);
    });
    child.on("close", (code) => {
      if (timer) clearTimeout(timer);
      const duration = performance.now() - start;
      const resultJson = parseJson(stdout.trim());
      const urls = extractUrls(`${stdout}\n${stderr}`);
      resolve({
        ok: code === 0,
        name,
        exit_code: code ?? 1,
        duration_ms: Math.round(duration),
        stdout: stdout.trim(),
        stderr: stderr.trim(),
        result_json: resultJson ?? undefined,
        urls: urls.length ? urls : undefined,
      });
    });
  });
}
