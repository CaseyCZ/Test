#!/usr/bin/env node
/**
 * Private receiver for TCL C835 PlayCaption diagnostic events.
 * Run behind your OWN HTTPS reverse proxy; this HTTP process binds 127.0.0.1.
 * No GitHub tokens in the Android app, no published logs.
 */
"use strict";
const http = require("node:http");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const HOST = "127.0.0.1";
const PORT = Number(process.env.PORT || 41690);
const ROOT = process.env.TCL_LOG_DIR || path.join(process.cwd(), "private-logs");
const STORE = path.join(ROOT, "devices.json");
const PAIR_UNTIL = process.env.TCL_PAIR_FIRST_DEVICE === "yes"
  ? Date.now() + 10 * 60 * 1000 : 0;
const MAX_BYTES = 100_000;
const RATE_MS = 50_000;
const RECENT_DAYS = 14;
const lastAccepted = new Map();

fs.mkdirSync(ROOT, { recursive: true, mode: 0o700 });
try { fs.chmodSync(ROOT, 0o700); } catch {}
let devices = {};
if (fs.existsSync(STORE)) {
  devices = JSON.parse(fs.readFileSync(STORE, "utf8"));
}

function reply(res, code, msg) {
  res.writeHead(code, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  });
  res.end(JSON.stringify({ status: msg }));
}

function purgeOld() {
  const threshold = Date.now() - RECENT_DAYS * 86400000;
  for (const file of fs.readdirSync(ROOT)) {
    if (!/^tcl-[a-f0-9]{24}-\d{4}-\d\d-\d\d\.jsonl$/.test(file)) continue;
    const name = path.join(ROOT, file);
    try {
      if (fs.statSync(name).mtimeMs < threshold) fs.unlinkSync(name);
    } catch {}
  }
}
purgeOld();

const srv = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    return reply(res, 200, "ok");
  }
  if (req.method !== "POST" || req.url !== "/v1/logs") {
    return reply(res, 404, "not_found");
  }
  if (!String(req.headers["content-type"] || "").startsWith("application/json")) {
    return reply(res, 415, "json_required");
  }
  if (Number(req.headers["content-length"] || "0") > MAX_BYTES) {
    return reply(res, 413, "too_large");
  }

  let bytes = 0;
  const chunks = [];
  req.on("data", chunk => {
    bytes += chunk.length;
    if (bytes > MAX_BYTES) {
      req.destroy();
      return;
    }
    chunks.push(chunk);
  });
  req.on("end", () => {
    try {
      const message = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      if (!/^[a-f0-9]{24}$/.test(message.deviceId || "")) return reply(res, 400, "invalid_device_id");
      if (typeof message.publicKey !== "string" || message.publicKey.length > 600 ||
          typeof message.bodyBase64 !== "string" || message.bodyBase64.length > MAX_BYTES ||
          typeof message.signature !== "string" || message.signature.length > 500) {
        return reply(res, 400, "invalid_packet");
      }
      const pubDer = Buffer.from(message.publicKey, "base64");
      const publicId = crypto.createHash("sha256").update(pubDer).digest("hex").slice(0, 24);
      if (publicId !== message.deviceId) return reply(res, 400, "device_mismatch");
      const pub = crypto.createPublicKey({ key: pubDer, format: "der", type: "spki" });
      if (pub.asymmetricKeyType !== "ec" ||
          pub.asymmetricKeyDetails?.namedCurve !== "prime256v1") {
        return reply(res, 400, "unsupported_key");
      }
      const body = Buffer.from(message.bodyBase64, "base64");
      if (body.length > 64_000) return reply(res, 413, "body_too_large");
      const signature = Buffer.from(message.signature, "base64");
      if (!crypto.verify("sha256", body, pub, signature)) return reply(res, 403, "bad_signature");

      const id = message.deviceId;
      if (!devices[id]) {
        if (PAIR_UNTIL < Date.now() || Object.keys(devices).length !== 0) {
          return reply(res, 403, "not_paired");
        }
        // One-time pairing: only the first enrolled device within 10 minutes.
        devices[id] = message.publicKey;
        fs.writeFileSync(STORE, JSON.stringify(devices, null, 2) + "\n", { mode: 0o600 });
        console.log("TCL device paired:", id);
      } else if (devices[id] !== message.publicKey) {
        return reply(res, 403, "key_mismatch");
      }

      const parsed = JSON.parse(body.toString("utf8"));
      if (parsed.schema !== 1 || !Array.isArray(parsed.lines) ||
          parsed.lines.length > 140 || parsed.lines.length === 0 ||
          typeof parsed.sentAtMs !== "number" ||
          Math.abs(Date.now() - parsed.sentAtMs) > 24 * 60 * 60 * 1000) {
        return reply(res, 400, "invalid_report");
      }
      const safe = parsed.lines.every(line =>
        typeof line === "string" && line.length <= 450 &&
        /^\d{2}:\d{2}:\d{2}\.\d{3} \[TCLDBG pid=\d+ sid=[0-9a-f]+ uptimeMs=\d+\] /.test(line) &&
        /\[(INPUT|RP |RTC|OVERLAY|TV RECEIVE|ONLINE CONFIG)/.test(line));
      if (!safe) return reply(res, 400, "unsupported_log_content");
      const previous = lastAccepted.get(id) || 0;
      if (Date.now() - previous < RATE_MS) return reply(res, 429, "rate_limited");
      lastAccepted.set(id, Date.now());

      const day = new Date().toISOString().slice(0, 10);
      const name = path.join(ROOT, "tcl-" + id + "-" + day + ".jsonl");
      fs.appendFileSync(name, JSON.stringify({
        receivedAt: new Date().toISOString(),
        deviceId: id,
        sentAtMs: parsed.sentAtMs,
        lines: parsed.lines,
      }) + "\n", { mode: 0o600 });
      reply(res, 200, "received");
    } catch (e) {
      console.error("Reject invalid TCL packet:", e.name);
      reply(res, 400, "invalid_request");
    }
  });
});
srv.listen(PORT, HOST, () => {
  console.log("TCL diagnostics collector on http://" + HOST + ":" + PORT);
  console.log("Pairing new device:", PAIR_UNTIL ? "ON for 10 minutes" : "OFF");
});
