import { RunbookEntry, RunbookStep, RunbookParallel } from "./runbooks.js";
import { RunResult } from "./tool-runner.js";

type StepResult = RunResult;

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

export async function runRunbook(
  runbook: RunbookEntry,
  runner: (name: string, input: Record<string, unknown>) => Promise<RunResult>,
  input: Record<string, unknown> = {},
  onStepStart?: (id: string, tool: string) => void,
  onStepFinish?: (id: string, tool: string, result: RunResult) => void
) {
  const results: Record<string, StepResult> = {};
  const ctx: Context = { vars: { ...(runbook.vars ?? {}), ...input }, steps: results };
  const steps = (runbook.steps ?? []) as Array<RunbookStep | RunbookParallel>;

  for (const step of steps) {
    if ((step as RunbookParallel).parallel) {
      const group = (step as RunbookParallel).parallel;
      const groupResults = await Promise.all(
        group.map(async (g) => {
          onStepStart?.(g.id, g.tool);
          const resolvedInput = (applyTemplate(g.input ?? {}, ctx) as Record<string, unknown>) ?? {};
          const res = await runner(g.tool, resolvedInput);
          onStepFinish?.(g.id, g.tool, res);
          return { id: g.id, res };
        })
      );
      for (const { id, res } of groupResults) {
        results[id] = res;
      }
      if (groupResults.some(({ res }) => !res.ok)) {
        return { ok: false, results };
      }
      continue;
    }

    const s = step as RunbookStep;
    onStepStart?.(s.id, s.tool);
    const resolvedInput = (applyTemplate(s.input ?? {}, ctx) as Record<string, unknown>) ?? {};
    const res = await runner(s.tool, resolvedInput);
    results[s.id] = res;
    onStepFinish?.(s.id, s.tool, res);
    if (!res.ok) {
      return { ok: false, results };
    }
  }
  return { ok: true, results };
}
