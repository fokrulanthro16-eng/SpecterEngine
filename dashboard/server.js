/**
 * SpecterEngine Terminal Telemetry Cockpit Server
 * Serves real-time WebSocket telemetry bridge, serving 60 FPS oscilloscope data,
 * Reactive Omni block intervals, anomaly score tensor spikes, and airlock ledger.
 */

const http = require("http");
const fs = require("fs");
const path = require("path");
const { WebSocketServer, WebSocket } = require("ws");

const PORT = process.env.PORT || 3000;
const PUBLIC_DIR = path.join(__dirname, "public");

// State
let baseSepoliaBlock = 18_942_110;
let reactiveBlock = 1_420_850;
let poolReserve0 = 100.0;
let poolReserve1 = 300_000.0;
let nominalReserve0 = 100.0;
let nominalReserve1 = 300_000.0;
let isQuarantined = false;
let quarantinedUntil = 0;
let quarantineHistory = [];
let recentIncidents = [];

// HTTP Server
const server = http.createServer((req, res) => {
  let reqPath = req.url.split("?")[0];
  if (reqPath === "/" || reqPath === "/dashboard") {
    reqPath = "/index.html";
  }

  const filePath = path.join(PUBLIC_DIR, reqPath);

  // Security check: ensure path stays within PUBLIC_DIR
  if (!filePath.startsWith(PUBLIC_DIR)) {
    res.writeHead(403);
    res.end("Forbidden");
    return;
  }

  // Handle REST endpoints
  if (req.method === "POST" && reqPath === "/api/trigger-exploit") {
    triggerExploit();
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "EXPLOIT_TRIGGERED" }));
    return;
  }

  if (req.method === "POST" && reqPath === "/api/reset-airlock") {
    isQuarantined = false;
    quarantinedUntil = 0;
    poolReserve0 = 100.0;
    poolReserve1 = 300_000.0;
    broadcast({
      type: "AIRLOCK_STATUS",
      isQuarantined: false,
      timestamp: Date.now()
    });
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "AIRLOCK_RESET" }));
    return;
  }

  // Serve static files
  fs.readFile(filePath, (err, content) => {
    if (err) {
      if (err.code === "ENOENT") {
        res.writeHead(404, { "Content-Type": "text/plain" });
        res.end("Not Found");
      } else {
        res.writeHead(500);
        res.end(`Server Error: ${err.code}`);
      }
    } else {
      let contentType = "text/html";
      const ext = path.extname(filePath);
      if (ext === ".js") contentType = "text/javascript";
      if (ext === ".css") contentType = "text/css";
      if (ext === ".json") contentType = "application/json";
      if (ext === ".svg") contentType = "image/svg+xml";

      res.writeHead(200, { "Content-Type": contentType });
      res.end(content, "utf-8");
    }
  });
});

// WebSocket Server
const wss = new WebSocketServer({ server });

function broadcast(data) {
  const payload = JSON.stringify(data);
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) {
      client.send(payload);
    }
  }
}

wss.on("connection", (ws) => {
  // Send initial topology & state
  ws.send(JSON.stringify({
    type: "INITIAL_STATE",
    baseSepoliaBlock,
    reactiveBlock,
    isQuarantined,
    quarantinedUntil,
    poolReserve0,
    poolReserve1,
    nominalReserve0,
    nominalReserve1,
    quarantineHistory
  }));

  ws.on("message", (message) => {
    try {
      const data = JSON.parse(message);
      if (data.action === "TRIGGER_EXPLOIT") {
        triggerExploit();
      } else if (data.action === "RESET_AIRLOCK") {
        isQuarantined = false;
        quarantinedUntil = 0;
        poolReserve0 = 100.0;
        poolReserve1 = 300_000.0;
        broadcast({
          type: "AIRLOCK_STATUS",
          isQuarantined: false,
          timestamp: Date.now()
        });
      }
    } catch (e) {
      console.error("Invalid WS message:", e);
    }
  });
});

function triggerExploit() {
  if (isQuarantined) return;

  const tStart = performance.now();
  // Simulate massive flash borrow: 82% reserve shock
  poolReserve0 = 18.0; // 82 ETH drained
  const reserveDeltaBps = 8200;
  const slippageVelocity = 123000;
  const priorityGas = 65.0;

  // Tensor score spike computation: S_t = 0.45*(ΔR/R) + 0.35*(∇Slip/σ) + 0.20*(G/G_bar)
  const alpha = 0.45;
  const beta = 0.35;
  const gamma = 0.20;
  const score = (alpha * 0.82) + (beta * 123.0) + (gamma * 65.0); // ~56.4

  const incidentHash = "0x" + Array.from({ length: 64 }, () => Math.floor(Math.random() * 16).toString(16)).join("");
  const duration = 3600;
  isQuarantined = true;
  quarantinedUntil = Date.now() + (duration * 1000);

  const incidentRecord = {
    incidentHash: incidentHash.slice(0, 10) + "..." + incidentHash.slice(-8),
    fullHash: incidentHash,
    pool: "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB",
    triggerSource: "Sentinel EIP-712 (0xDB6ea...1Bb7)",
    riskScore: "99.85%",
    durationSec: duration,
    timestamp: new Date().toLocaleTimeString(),
    quarantinedUntil: new Date(quarantinedUntil).toLocaleTimeString(),
    latencyMs: 14.54,
    inferenceMs: 0.389
  };

  quarantineHistory.unshift(incidentRecord);
  if (quarantineHistory.length > 10) quarantineHistory.pop();

  broadcast({
    type: "THREAT_SPIKE",
    score,
    isQuarantined: true,
    quarantinedUntil,
    incident: incidentRecord,
    reserves: { reserve0: poolReserve0, reserve1: poolReserve1 }
  });
}

// 60 FPS Telemetry Stream Loop (~16.6ms tick)
let tickCounter = 0;
setInterval(() => {
  tickCounter++;
  const now = Date.now();

  // Baseline fluctuations
  let currentScore = 0.04 + (Math.sin(tickCounter * 0.1) * 0.02) + (Math.random() * 0.02);
  let slippage = 5.0 + (Math.cos(tickCounter * 0.08) * 3.0);
  let gasPriority = 1.0 + (Math.random() * 0.5);

  // Auto-expire quarantine if expired
  if (isQuarantined && now >= quarantinedUntil) {
    isQuarantined = false;
    quarantinedUntil = 0;
    poolReserve0 = 100.0;
    broadcast({
      type: "AIRLOCK_STATUS",
      isQuarantined: false,
      timestamp: now
    });
  }

  // Broadcast 60 FPS Oscilloscope Frame
  broadcast({
    type: "OSCILLOSCOPE_TICK",
    timestamp: now,
    score: isQuarantined ? 0.95 : currentScore,
    slippage: slippage,
    gasPriority: gasPriority,
    isQuarantined: isQuarantined
  });
}, 16);

// Base Sepolia Block Increment (~200ms)
setInterval(() => {
  baseSepoliaBlock++;
  broadcast({
    type: "BASE_SEPOLIA_BLOCK",
    blockNumber: baseSepoliaBlock,
    timestamp: Date.now()
  });
}, 200);

// Reactive Omni Block Increment (~1000ms / 1.0s CometBFT)
setInterval(() => {
  reactiveBlock++;
  broadcast({
    type: "REACTIVE_BLOCK",
    blockNumber: reactiveBlock,
    timestamp: Date.now()
  });
}, 1000);

server.listen(PORT, () => {
  console.log(`SpecterEngine Telemetry Cockpit running at: http://localhost:${PORT}`);
  console.log(`WebSocket Telemetry Bridge listening on ws://localhost:${PORT}`);
});
