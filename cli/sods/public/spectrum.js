const canvas = document.getElementById("field");
const ctx = canvas.getContext("2d");
const statusEl = document.getElementById("status");
const pauseBtn = document.getElementById("pauseBtn");
const windowGroup = document.getElementById("windowGroup");
const nodeFilterInput = document.getElementById("nodeFilter");
const capRange = document.getElementById("capRange");
const capValue = document.getElementById("capValue");
const godBtn = document.getElementById("godBtn");
const toolsMenu = document.getElementById("toolsMenu");
const toolsList = document.getElementById("toolsList");
const toolsOutput = document.getElementById("toolsOutput");
const closeTools = document.getElementById("closeTools");

let paused = false;
let timeWindowMs = 15000;
let deviceCap = Number(capRange.value);
let nodeFilter = "";

capValue.textContent = String(deviceCap);

pauseBtn.addEventListener("click", () => {
  paused = !paused;
  pauseBtn.textContent = paused ? "Resume" : "Pause";
});

windowGroup.addEventListener("click", (e) => {
  const btn = e.target.closest("button[data-window]");
  if (!btn) return;
  timeWindowMs = Number(btn.dataset.window);
  windowGroup.querySelectorAll("button").forEach((b) => b.classList.remove("active"));
  btn.classList.add("active");
});

nodeFilterInput.addEventListener("input", () => {
  nodeFilter = nodeFilterInput.value.trim();
});

capRange.addEventListener("input", () => {
  deviceCap = Number(capRange.value);
  capValue.textContent = String(deviceCap);
});


const trails = new Map();
const maxTrailPoints = 80;

function resize() {
  const ratio = window.devicePixelRatio || 1;
  canvas.width = canvas.clientWidth * ratio;
  canvas.height = canvas.clientHeight * ratio;
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
}

window.addEventListener("resize", resize);
resize();

function pushTrail(frame) {
  if (!trails.has(frame.device_id)) {
    trails.set(frame.device_id, []);
  }
  const list = trails.get(frame.device_id);
  list.push(frame);
  if (list.length > maxTrailPoints) list.splice(0, list.length - maxTrailPoints);
}

function renderFrame() {
  requestAnimationFrame(renderFrame);
  if (paused) return;

  const now = Date.now();
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;

  ctx.clearRect(0, 0, width, height);
  drawBackground(width, height, now);

  const active = Array.from(trails.entries())
    .map(([id, list]) => ({ id, list }))
    .sort((a, b) => (b.list.at(-1)?.persistence ?? 0) - (a.list.at(-1)?.persistence ?? 0))
    .slice(0, deviceCap);

  for (const { list } of active) {
    drawTrail(list, width, height, now);
  }

  ctx.fillStyle = "rgba(255,255,255,0.4)";
  ctx.font = "11px SF Pro Text, system-ui";
  ctx.fillText("All outputs are inferred / correlated", 16, height - 18);
}

function drawBackground(width, height, now) {
  const gradient = ctx.createLinearGradient(0, 0, width, height);
  gradient.addColorStop(0, "rgba(14, 6, 8, 1)");
  gradient.addColorStop(0.5, "rgba(6, 6, 8, 1)");
  gradient.addColorStop(1, "rgba(5, 5, 7, 1)");
  ctx.fillStyle = gradient;
  ctx.fillRect(0, 0, width, height);

  ctx.save();
  ctx.strokeStyle = "rgba(255,60,60,0.08)";
  ctx.lineWidth = 1;
  const grid = 42;
  for (let x = 0; x < width; x += grid) {
    ctx.beginPath();
    ctx.moveTo(x, 0);
    ctx.lineTo(x, height);
    ctx.stroke();
  }
  for (let y = 0; y < height; y += grid) {
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(width, y);
    ctx.stroke();
  }
  ctx.restore();

  const pulse = 0.6 + 0.4 * Math.sin(now * 0.0004);
  ctx.fillStyle = `rgba(255, 60, 60, ${0.08 * pulse})`;
  ctx.beginPath();
  ctx.arc(width * 0.5, height * 0.55, 280, 0, Math.PI * 2);
  ctx.fill();
}

function drawTrail(list, width, height, now) {
  const recent = list.filter((f) => now - f.t <= timeWindowMs);
  if (recent.length === 0) return;

  const last = recent[recent.length - 1];
  const x = mapFrequency(last.frequency, width);
  const baseY = mapDepth(last, height);

  ctx.save();
  ctx.strokeStyle = colorWithAlpha(last.color, 0.28);
  ctx.lineWidth = 2 + last.persistence * 6;
  ctx.beginPath();
  for (let i = 0; i < recent.length; i++) {
    const frame = recent[i];
    const fx = mapFrequency(frame.frequency, width);
    const fy = mapDepth(frame, height) + jitter(frame.device_id, i) * 8;
    if (i === 0) ctx.moveTo(fx, fy);
    else ctx.lineTo(fx, fy);
  }
  ctx.stroke();

  const glow = 14 + (last.glow ?? 0.3) * 34 + last.persistence * 18;
  ctx.fillStyle = colorWithAlpha(last.color, 0.22 + (last.glow ?? 0.3) * 0.4);
  ctx.beginPath();
  ctx.ellipse(x, baseY, glow, glow * 0.7, 0, 0, Math.PI * 2);
  ctx.fill();

  ctx.fillStyle = colorWithAlpha(last.color, 0.9);
  ctx.beginPath();
  ctx.ellipse(x, baseY, 3 + last.persistence * 6, 3 + last.persistence * 5, 0, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();
}

function mapDepth(frame, height) {
  const strength = clamp((frame.rssi + 95) / 60, 0, 1);
  const depth = 0.2 + strength * 0.75;
  return height * (0.15 + (1 - depth) * 0.75);
}

function mapFrequency(freq, width) {
  if (freq < 3000) {
    return width * ((freq - 2400) / 200);
  }
  const f = clamp((freq - 5000) / 900, 0, 1);
  return width * (0.55 + f * 0.45);
}

function colorWithAlpha(color, alpha) {
  return `hsla(${color.h}, ${Math.round(color.s * 100)}%, ${Math.round(color.l * 100)}%, ${alpha})`;
}

function clamp(v, min, max) {
  return Math.max(min, Math.min(max, v));
}

function jitter(seed, idx) {
  let h = 2166136261;
  for (let i = 0; i < seed.length; i++) h ^= seed.charCodeAt(i);
  h = Math.imul(h + idx * 1013, 16777619);
  return ((h >>> 0) % 1000) / 1000 - 0.5;
}

let ws;

function connectWS() {
  const url = new URL("/ws/frames", window.location.href);
  url.protocol = url.protocol.replace("http", "ws");
  ws = new WebSocket(url.toString());
  ws.addEventListener("open", () => {
    statusEl.textContent = "live";
  });
  ws.addEventListener("close", () => {
    statusEl.textContent = "disconnected";
  });
  ws.addEventListener("message", (event) => {
    const payload = JSON.parse(event.data);
    const frames = payload.frames ?? [];
    for (const frame of frames) {
      if (nodeFilter && frame.node_id !== nodeFilter) continue;
      pushTrail(frame);
    }
  });
}

function resetStream() {
  if (ws) {
    ws.close();
    ws = null;
  }
  connectWS();
}

async function openTools() {
  toolsMenu.classList.remove("hidden");
  toolsOutput.textContent = "";
  const res = await fetch("/tools");
  const data = await res.json();
  toolsList.innerHTML = "";
  for (const tool of data.items ?? []) {
    const card = document.createElement("div");
    card.className = "tool-card";
    card.innerHTML = `<div><strong>${tool.name}</strong> <span class="muted">${tool.scope}</span></div>
      <div>input: ${tool.input}</div>
      <div>output: ${tool.output}</div>
      <div>mode: ${tool.kind}</div>
      <button class="capsule">Run</button>`;
    const btn = card.querySelector("button");
    btn.addEventListener("click", async () => {
      const input = {};
      if (tool.input.includes("required")) {
        const raw = prompt(`Input for ${tool.name} (JSON)`);
        if (!raw) return;
        try { Object.assign(input, JSON.parse(raw)); } catch { alert("Invalid JSON"); return; }
      }
      const resp = await fetch("/tools/run", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: tool.name, input }) });
      toolsOutput.textContent = await resp.text();
    });
    toolsList.appendChild(card);
  }
}

godBtn.addEventListener("click", openTools);
closeTools.addEventListener("click", () => toolsMenu.classList.add("hidden"));

toolsMenu.addEventListener("click", (e) => {
  if (e.target === toolsMenu) toolsMenu.classList.add("hidden");
});

resetStream();
renderFrame();
