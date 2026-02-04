import { PresetEntry } from "./presets.js";
import { RunResult } from "./tool-runner.js";

type StepResult = RunResult;

type Step = {
  id: string;
  tool: string;
  input?: Record<string, unknown>;
};

type ParallelGroup = {
  parallel: Step[];
};

type MacroStep = Step | ParallelGroup;

type Context = {
  vars: Record<string, unknown>;
  steps: Record<string, StepResult>;
};

function resolveToken(token: string, ctx: Context): unknown {
  if (Object.prototype.hasOwnProperty.call(ctx.vars, token)) {
    return ctx.vars[token];
  }
  const [stepId, propRaw] = token.split(".", 2);
  if (!propRaw || !ctx.steps[stepId]) return undefined;
  const step = ctx.steps[stepId];
  let prop = propRaw;
  let index: number | null = null;
  const match = propRaw.match(/^([a-zA-Z_]+)\[(\d+)\]$/);
  if (match) {
    prop = match[1];
    index = Number(match[2]);
  }
  let value: any = (step as any)[prop];
  if (prop === "result_json") value = step.result_json;
  if (prop === "urls") value = step.urls;
  if (index !== null && Array.isArray(value)) return value[index];
  return value;
}

function applyTemplate(value: unknown, ctx: Context): unknown {
  if (typeof value === "string") {
    const fullMatch = value.match(/^\$\{([^}]+)\}$/);
    if (fullMatch) {
      const resolved = resolveToken(fullMatch[1], ctx);
      return resolved !== undefined ? resolved : value;
    }
    return value.replace(/\$\{([^}]+)\}/g, (_m, token) => {
      const resolved = resolveToken(token, ctx);
      if (resolved === undefined || resolved === null) return "";
      if (typeof resolved === "string") return resolved;
      return JSON.stringify(resolved);
    });
  }
  if (Array.isArray(value)) {
    return value.map((item) => applyTemplate(item, ctx));
  }
  if (value && typeof value === "object") {
    const next: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) {
      next[k] = applyTemplate(v, ctx);
    }
    return next;
  }
  return value;
}

export async function runPreset(
  preset: PresetEntry,
  runner: (name: string, input: Record<string, unknown>) => Promise<RunResult>
) {
  const results: Record<string, StepResult> = {};
  const ctx: Context = { vars: preset.vars ?? {}, steps: results };

  if (preset.kind === "single" && preset.tool) {
    const input = (applyTemplate(preset.input ?? {}, ctx) as Record<string, unknown>) ?? {};
    const res = await runner(preset.tool, input);
    results[preset.id] = res;
    return { ok: res.ok, results };
  }

  const steps = (preset.steps ?? []) as MacroStep[];
  for (const step of steps) {
    if ((step as ParallelGroup).parallel) {
      const group = (step as ParallelGroup).parallel;
      const groupResults = await Promise.all(
        group.map(async (g) => {
          const input = (applyTemplate(g.input ?? {}, ctx) as Record<string, unknown>) ?? {};
          const res = await runner(g.tool, input);
          return { id: g.id, res };
        })
      );
      for (const { id, res } of groupResults) {
        results[id] = res;
      }
      continue;
    }
    const s = step as Step;
    const input = (applyTemplate(s.input ?? {}, ctx) as Record<string, unknown>) ?? {};
    const res = await runner(s.tool, input);
    results[s.id] = res;
    if (!res.ok) {
      return { ok: false, results };
    }
  }
  return { ok: true, results };
}
