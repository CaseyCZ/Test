#!/usr/bin/env node
"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");
const http = require("node:http");

function post(data) {
  return new Promise((resolve, reject) => {
    const bytes = Buffer.from(JSON.stringify(data), "utf8");
    const req = http.request({
      hostname: "127.0.0.1", port: 41691, path: "/v1/logs",
      method: "POST",
      headers: { "Content-Type": "application/json", "Content-Length": bytes.length },
    }, res => {
      let body = "";
      res.on("data", c => { body += c; });
      res.on("end", () => resolve({ status: res.statusCode, body }));
    });
    req.on("error", reject);
    req.end(bytes);
  });
}

function packet(pair, log) {
  const key = pair.publicKey.export({ type: "spki", format: "der" });
  const payload = Buffer.from(JSON.stringify({
    schema: 1, sentAtMs: Date.now(), lines: [
      "12:01:01.123 [TCLDBG pid=123 sid=abc123 uptimeMs=1000] [RTC] " + log
    ]
  }), "utf8");
  return {
    deviceId: crypto.createHash("sha256").update(key).digest("hex").slice(0, 24),
    publicKey: key.toString("base64"),
    bodyBase64: payload.toString("base64"),
    signature: crypto.sign("sha256", payload, pair.privateKey).toString("base64"),
  };
}

test("collector: pairing, authentication, rate limit and private storage", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "tcl-log-test-"));
  const child = spawn(process.execPath, [path.join(__dirname, "server.cjs")], {
    env: { ...process.env, PORT: "41691", TCL_LOG_DIR: root,
      TCL_PAIR_FIRST_DEVICE: "yes" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  try {
    let ready = false;
    for (let i = 0; i < 40; i++) {
      await new Promise(r => setTimeout(r, 50));
      if (child.exitCode !== null) throw new Error("Collector exited before ready");
      try {
        const r = await new Promise((resolve, reject) => {
          http.get("http://127.0.0.1:41691/health", resp => {
            resp.resume();
            resolve(resp);
          }).on("error", reject);
        });
        if (r.statusCode === 200) { ready = true; break; }
      } catch {}
    }
    assert.ok(ready, "collector did not start");
    const device = crypto.generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const other = crypto.generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const ok = await post(packet(device, "[Xbox] ICE: DISCONNECTED"));
    assert.equal(ok.status, 200, ok.body);
    const repeat = await post(packet(device, "[Xbox] ICE: FAILED"));
    assert.equal(repeat.status, 429, repeat.body);
    const unknown = await post(packet(other, "[Xbox] ICE: CONNECTED"));
    assert.equal(unknown.status, 403, unknown.body);
    const stored = fs.readdirSync(root).filter(n => n.endsWith(".jsonl"));
    assert.equal(stored.length, 1);
    assert.ok(fs.readFileSync(path.join(root, stored[0]), "utf8")
      .includes("[Xbox] ICE: DISCONNECTED"));
  } finally {
    child.kill("SIGTERM");
    fs.rmSync(root, { recursive: true, force: true });
  }
});
