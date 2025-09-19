// tts_load_balancer.js
// Minimal, config-driven TTS load balancer (CommonJS, Node 18+)
// Reads ./load_balancer_config.json (must be present)

const fs = require("fs");
const path = require("path");
const express = require("express");

// Load config (synchronous on startup)
const CONFIG_PATH = path.resolve(__dirname, "load_balancer_config.json");
let cfg;
try {
  cfg = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
} catch (e) {
  console.error(`Failed to read config at ${CONFIG_PATH}:`, e && e.message ? e.message : e);
  process.exit(1);
}

// Apply config values with sensible fallbacks
const PORT = Number(cfg.port || 3000);
const TTS_PORTS = Array.isArray(cfg.tts_instances) ? cfg.tts_instances : [];
const HEALTH_INTERVAL_MS = Number(cfg.health_check_interval ?? 30000);
const HEALTH_TIMEOUT_MS = Number(cfg.health_check_timeout ?? 5000);
const MAX_ACTIVE = Number(cfg.max_active_requests ?? 4);
const UPSTREAM_TIMEOUT_MS = Number(cfg.request_timeout ?? 30000);
const MAX_CONSEC_FAILS = Number(cfg.max_consecutive_failures ?? 10);
const CIRCUIT_BREAKER_MS = Number(cfg.circuit_breaker_timeout ?? 180000);

const HEALTH_PATH = "/health";

const app = express();
app.use(express.json({ limit: "2mb" }));

// Instance state (one entry per port)
const instances = TTS_PORTS.map(p => ({
  port: Number(p),
  url: `http://localhost:${p}`,
  healthy: false,
  activeRequests: 0,
  consecutiveFailures: 0,
  circuitOpenUntil: 0,
  lastChecked: 0
}));

// Probe one instance using Node 18 global fetch + AbortController
async function probeInstance(inst) {
  // Skip probing while circuit is open (will be rechecked later)
  if (Date.now() < inst.circuitOpenUntil) {
    inst.healthy = false;
    inst.lastChecked = Date.now();
    return;
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), HEALTH_TIMEOUT_MS);

  try {
    const res = await fetch(inst.url + HEALTH_PATH, { method: "GET", signal: controller.signal });
    inst.healthy = res.ok;
    if (res.ok) {
      inst.consecutiveFailures = 0;
    } else {
      inst.consecutiveFailures++;
    }
  } catch (err) {
    inst.healthy = false;
    inst.consecutiveFailures++;
  } finally {
    clearTimeout(timer);
    inst.lastChecked = Date.now();
    // open circuit if failures exceeded
    if (inst.consecutiveFailures >= MAX_CONSEC_FAILS) {
      inst.circuitOpenUntil = Date.now() + CIRCUIT_BREAKER_MS;
      inst.consecutiveFailures = 0; // reset after opening circuit
      console.warn(`Circuit OPEN for ${inst.url} until ${new Date(inst.circuitOpenUntil).toISOString()}`);
    }
  }
}

// Run health checks in parallel
async function runHealthChecks() {
  await Promise.all(instances.map(i => probeInstance(i)));
}

// Start periodic health checks
runHealthChecks().catch(() => {});
setInterval(() => runHealthChecks().catch(() => {}), HEALTH_INTERVAL_MS);

// Pick instance: healthy, circuit closed, activeRequests < MAX_ACTIVE, pick min activeRequests
function pickInstance() {
  const now = Date.now();
  const candidates = instances.filter(i =>
    i.healthy &&
    now >= i.circuitOpenUntil &&
    i.activeRequests < MAX_ACTIVE
  );
  if (candidates.length === 0) return null;
  candidates.sort((a, b) => a.activeRequests - b.activeRequests);
  return candidates[0];
}

// LB health endpoint
app.get("/health", (req, res) => {
  const healthyCount = instances.filter(i => i.healthy && Date.now() >= i.circuitOpenUntil).length;
  res.json({
    status: healthyCount > 0 ? "ok" : "degraded",
    healthyCount,
    instances: instances.map(i => ({
      url: i.url,
      healthy: i.healthy,
      activeRequests: i.activeRequests,
      circuitOpenUntil: i.circuitOpenUntil,
      lastChecked: i.lastChecked
    }))
  });
});

// Proxy /generate -> selected instance's /generate
app.post("/generate", async (req, res) => {
  const inst = pickInstance();
  if (!inst) {
    // No selectable TTS instance
    res.status(503).json({
      error: true,
      message: "No TTS instance available. Please try again later.",
      play_signal: "NO_TTS_AVAILABLE"
    });
    return;
  }

  // increment active
  inst.activeRequests += 1;
  let timedOut = false;

  try {
    const controller = new AbortController();
    const timer = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, UPSTREAM_TIMEOUT_MS);

    const upstream = await fetch(inst.url + "/generate", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(req.body || {}),
      signal: controller.signal
    });

    clearTimeout(timer);

    // propagate status and safe headers
    res.status(upstream.status);
    upstream.headers.forEach((v, k) => {
      const kl = k.toLowerCase();
      if (!["connection", "keep-alive", "transfer-encoding", "upgrade"].includes(kl)) {
        res.setHeader(k, v);
      }
    });

    // If streaming body present, pipe it
    if (upstream.body) {
      upstream.body.pipe(res);
      // ensure any upstream errors mark instance unhealthy
      upstream.body.on("error", (err) => {
        console.error("Upstream body error:", err && err.message ? err.message : err);
        inst.healthy = false;
      });
    } else {
      const txt = await upstream.text().catch(() => "");
      res.send(txt);
    }

    // Successful upstream response -> reset consecutiveFailures
    if (upstream.ok) inst.consecutiveFailures = 0;
    else inst.consecutiveFailures++;

  } catch (err) {
    console.error(`Proxy error to ${inst.url}:`, err && err.message ? err.message : err);
    inst.healthy = false;
    inst.consecutiveFailures++;

    if (timedOut) {
      res.status(504).json({
        error: true,
        message: "TTS instance timed out.",
        play_signal: "TTS_INSTANCE_TIMEOUT"
      });
    } else {
      res.status(502).json({
        error: true,
        message: "TTS instance failure.",
        play_signal: "TTS_INSTANCE_FAILURE"
      });
    }

    // If failures exceed threshold, open circuit
    if (inst.consecutiveFailures >= MAX_CONSEC_FAILS) {
      inst.circuitOpenUntil = Date.now() + CIRCUIT_BREAKER_MS;
      inst.consecutiveFailures = 0;
      console.warn(`Circuit OPEN for ${inst.url} until ${new Date(inst.circuitOpenUntil).toISOString()}`);
    }
  } finally {
    // decrement activeRequests asynchronously to avoid race with immediate reads
    setImmediate(() => { inst.activeRequests = Math.max(0, inst.activeRequests - 1); });
  }
});

// debug stats
app.get("/_stats", (req, res) => {
  res.json(instances.map(i => ({
    url: i.url,
    healthy: i.healthy,
    activeRequests: i.activeRequests,
    consecutiveFailures: i.consecutiveFailures,
    circuitOpenUntil: i.circuitOpenUntil,
    lastChecked: i.lastChecked
  })));
});

app.listen(PORT, () => {
  console.log(`TTS load balancer listening on :${PORT}`);
  console.log("Using config:", CONFIG_PATH);
  console.log("Instances:", instances.map(i => i.url));
});
