import express from "express";
import { createHmac, randomUUID } from "node:crypto";

const app = express();
app.use(express.json());

const PORT = Number(process.env.PORT || 9123);
const HOST = process.env.HOST || "0.0.0.0";
const TOKEN_COMPAT_SECRET = (process.env.TOKEN_COMPAT_SECRET || "strangelab-token-compat-v1").trim();
const FED_GATEWAY_HEALTH_URL = process.env.FED_GATEWAY_HEALTH_URL || "http://127.0.0.1:9777/v1/health";
const FED_GATEWAY_BEARER = (process.env.FED_GATEWAY_BEARER || "").trim();
const TOKEN_HEALTH_TIMEOUT_MS = Number(process.env.TOKEN_HEALTH_TIMEOUT_MS || 2500);

function nowMs() {
  return Date.now();
}

function withTimeoutSignal(ms) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  return { controller, timer };
}

async function gatewayHealth() {
  const { controller, timer } = withTimeoutSignal(TOKEN_HEALTH_TIMEOUT_MS);
  try {
    const headers = { accept: "application/json" };
    if (FED_GATEWAY_BEARER) headers.authorization = `Bearer ${FED_GATEWAY_BEARER}`;
    const response = await fetch(FED_GATEWAY_HEALTH_URL, {
      method: "GET",
      headers,
      signal: controller.signal,
    });
    const text = await response.text();
    const body = (() => {
      try {
        return JSON.parse(text);
      } catch {
        return null;
      }
    })();

    if (!response.ok) {
      return { ok: false, detail: `HTTP ${response.status}` };
    }
    if (body && body.ok === true) {
      return { ok: true, detail: "ok" };
    }
    return { ok: false, detail: body?.error?.message || text || "invalid health response" };
  } catch (error) {
    return { ok: false, detail: String(error?.message || error) };
  } finally {
    clearTimeout(timer);
  }
}

function compatToken(identity, room) {
  const payload = {
    v: 1,
    mode: "federation-compat",
    identity,
    room,
    ts_ms: nowMs(),
    nonce: randomUUID(),
  };
  const payloadJSON = JSON.stringify(payload);
  const payloadB64 = Buffer.from(payloadJSON, "utf8").toString("base64url");
  const sig = createHmac("sha256", TOKEN_COMPAT_SECRET)
    .update(payloadJSON)
    .digest("base64url");
  return `cgcompat.${payloadB64}.${sig}`;
}

app.get("/health", async (_req, res) => {
  const fed = await gatewayHealth();
  const status = {
    ok: true,
    service: "strangelab-token",
    mode: "federation-compat",
    port: PORT,
    federation_gateway_health_url: FED_GATEWAY_HEALTH_URL,
    federation_gateway_ok: fed.ok,
    federation_gateway_detail: fed.detail,
  };
  if (!fed.ok) {
    res.status(503).json({ ...status, ok: false });
    return;
  }
  res.json(status);
});

app.post("/token", async (req, res) => {
  const identity = String(req.body?.identity || "").trim();
  const room = String(req.body?.room || "").trim();

  if (!identity || !room) {
    res.status(400).json({ ok: false, error: "identity and room are required" });
    return;
  }

  const fed = await gatewayHealth();
  if (!fed.ok) {
    res.status(503).json({
      ok: false,
      error: `federation gateway unavailable: ${fed.detail}`,
      mode: "federation-compat",
    });
    return;
  }

  try {
    const token = compatToken(identity, room);
    res.json({ ok: true, token, mode: "federation-compat" });
  } catch (error) {
    res.status(500).json({ ok: false, error: String(error?.message || error), mode: "federation-compat" });
  }
});

app.listen(PORT, HOST, () => {
  console.log(`token server on http://${HOST}:${PORT} (federation compatibility mode)`);
});
