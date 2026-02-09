import express from "express";
import { AccessToken } from "livekit-server-sdk";

const app = express();
app.use(express.json());

const LIVEKIT_API_KEY = process.env.LIVEKIT_API_KEY || "devkey";
const LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET || "secret";
const PORT = Number(process.env.PORT || 9123);
const HOST = process.env.HOST || "0.0.0.0";

app.get("/health", (_req, res) => {
  res.json({ ok: true, service: "strangelab-token", port: PORT });
});

app.post("/token", async (req, res) => {
  const { identity, room } = req.body ?? {};

  if (!identity || !room) {
    res.status(400).json({ ok: false, error: "identity and room are required" });
    return;
  }

  try {
    const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, { identity });
    at.addGrant({
      room,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: true,
    });
    const token = await at.toJwt();
    res.json({ ok: true, token });
  } catch (error) {
    res.status(500).json({ ok: false, error: String(error?.message || error) });
  }
});

app.listen(PORT, HOST, () => {
  console.log(`token server on http://${HOST}:${PORT}`);
});
