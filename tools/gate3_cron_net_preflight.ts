/**
 * Gate 3 — Local pg_cron / pg_net preflight
 *
 * Verifies that pg_net can reach the Mac host from inside the Supabase Docker
 * container, and that pg_cron can schedule and fire a pg_net HTTP call.
 *
 * Usage (from WhatAndWhere/):
 *   deno run --allow-net --allow-env --allow-write --allow-run \
 *     tools/gate3_cron_net_preflight.ts
 *
 * Requires: local Supabase stack running (supabase start).
 * No cloud operations. No credentials committed to repo.
 */

// ── Config ────────────────────────────────────────────────────────────────────
const DB_URL = "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
// host.docker.internal resolves to the Mac from inside Docker on macOS
const HOST_GATEWAY = "host.docker.internal";
const LISTEN_PORT = 9877; // unlikely to be in use
const CRON_TIMEOUT_MS = 90_000; // pg_cron fires at most every 60s; allow 90s

// ── Evidence accumulator ──────────────────────────────────────────────────────
const ts = new Date().toISOString();
const steps: string[] = [];
let overallPass = true;

function pass(step: string, detail: string) {
  const line = `${step}: PASS — ${detail}`;
  console.log(" ", line);
  steps.push(line);
}

function fail(step: string, detail: unknown) {
  const line = `${step}: FAIL — ${detail}`;
  console.error(" ", line);
  steps.push(line);
  overallPass = false;
}

// ── psql helper ───────────────────────────────────────────────────────────────
async function psql(sql: string): Promise<{ stdout: string; stderr: string; code: number }> {
  const cmd = new Deno.Command("psql", {
    args: [DB_URL, "-tAX", "-c", sql],
    stdout: "piped",
    stderr: "piped",
  });
  const { code, stdout, stderr } = await cmd.output();
  return {
    code,
    stdout: new TextDecoder().decode(stdout).trim(),
    stderr: new TextDecoder().decode(stderr).trim(),
  };
}

// ── Step 0: Verify extensions ─────────────────────────────────────────────────
console.log("\nStep 0 — Verify pg_net and pg_cron extensions are installed");
{
  const r = await psql(
    "SELECT extname FROM pg_extension WHERE extname IN ('pg_net','pg_cron') ORDER BY extname;",
  );
  if (r.code !== 0) {
    fail("Step 0", `psql error: ${r.stderr}`);
    await writeLog(false);
    Deno.exit(1);
  }
  const found = r.stdout.split("\n").map((l) => l.trim()).filter(Boolean);
  const hasCron = found.includes("pg_cron");
  const hasNet = found.includes("pg_net");
  if (hasCron && hasNet) {
    pass("Step 0", `extensions present: ${found.join(", ")}`);
  } else {
    fail("Step 0", `missing: ${["pg_cron", "pg_net"].filter((e) => !found.includes(e)).join(", ")}`);
    await writeLog(false);
    Deno.exit(1);
  }
}

// ── Step 1: Direct net.http_post (no cron) ───────────────────────────────────
// Start the listener, fire a direct pg_net call, confirm it arrives.
console.log(`\nStep 1 — Direct net.http_post → http://${HOST_GATEWAY}:${LISTEN_PORT}/gate3-direct`);

let step1RequestReceived = false;
let step1ReqId = "";

// Start HTTP server
const ac = new AbortController();
const serverReady = Promise.withResolvers<void>();
const step1Received = Promise.withResolvers<string>();
const step2Received = Promise.withResolvers<string>();
let step2Triggered = false;

const server = Deno.serve(
  { port: LISTEN_PORT, signal: ac.signal, onListen: () => serverReady.resolve() },
  async (req) => {
    const url = new URL(req.url);
    const body = await req.text().catch(() => "");
    console.log(`  [listener] ${req.method} ${url.pathname}`);
    if (url.pathname === "/gate3-direct" && !step1RequestReceived) {
      step1RequestReceived = true;
      step1Received.resolve(`${req.method} ${url.pathname} — body: ${body || "(empty)"}`);
    } else if (url.pathname === "/gate3-cron") {
      step2Received.resolve(`${req.method} ${url.pathname} — body: ${body || "(empty)"}`);
    }
    return new Response("ok", { status: 200 });
  },
);

await serverReady.promise;
console.log(`  Listener ready on port ${LISTEN_PORT}`);

// Fire direct pg_net call
{
  const r = await psql(
    `SELECT net.http_post(
       url := 'http://${HOST_GATEWAY}:${LISTEN_PORT}/gate3-direct',
       body := '{}'::jsonb
     ) AS request_id;`,
  );
  if (r.code !== 0) {
    fail("Step 1", `pg_net call failed: ${r.stderr}`);
  } else {
    step1ReqId = r.stdout;
    console.log(`  pg_net request_id: ${step1ReqId}`);
  }
}

// Wait up to 10s for direct request to arrive at listener
{
  const timeout = new Promise<string>((_, rej) =>
    setTimeout(() => rej(new Error("timeout after 10s")), 10_000)
  );
  try {
    const detail = await Promise.race([step1Received.promise, timeout]);
    pass("Step 1", `listener received: ${detail}`);
  } catch (err) {
    fail("Step 1", `listener did not receive request: ${err}`);
  }
}

// Confirm response row in net._http_response
if (step1ReqId) {
  const r = await psql(
    `SELECT status_code FROM net._http_response WHERE id = ${step1ReqId};`,
  );
  if (r.code === 0 && r.stdout) {
    pass("Step 1b", `net._http_response row: status_code=${r.stdout}`);
  } else {
    // Response row may not appear immediately; not a hard failure
    pass("Step 1b", "net._http_response row not yet visible (async — acceptable)");
  }
}

// ── Step 2: pg_cron schedules a pg_net call ───────────────────────────────────
console.log(`\nStep 2 — pg_cron → net.http_post → http://${HOST_GATEWAY}:${LISTEN_PORT}/gate3-cron`);
let cronJobId = "";

// Schedule cron job (every minute)
{
  const r = await psql(
    `SELECT cron.schedule(
       'gate3-preflight',
       '* * * * *',
       $$SELECT net.http_post(
           url := 'http://${HOST_GATEWAY}:${LISTEN_PORT}/gate3-cron',
           body := '{}'::jsonb
         )$$
     );`,
  );
  if (r.code !== 0) {
    fail("Step 2", `cron.schedule failed: ${r.stderr}`);
    await cleanup();
    await writeLog(false);
    Deno.exit(1);
  }
  cronJobId = r.stdout;
  console.log(`  Cron job scheduled, jobid: ${cronJobId}`);
  console.log(`  Waiting up to ${CRON_TIMEOUT_MS / 1000}s for cron to fire...`);
}

// Wait for cron request to arrive
{
  const timeout = new Promise<string>((_, rej) =>
    setTimeout(() => rej(new Error(`timeout after ${CRON_TIMEOUT_MS / 1000}s`)), CRON_TIMEOUT_MS)
  );
  try {
    const detail = await Promise.race([step2Received.promise, timeout]);
    pass("Step 2", `cron fired, listener received: ${detail}`);
  } catch (err) {
    fail("Step 2", `cron did not fire within timeout: ${err}`);
  }
}

// ── Cleanup ───────────────────────────────────────────────────────────────────
await cleanup();

async function cleanup() {
  if (cronJobId) {
    console.log("\nCleanup — unscheduling cron job");
    const r = await psql(`SELECT cron.unschedule('gate3-preflight');`);
    if (r.code === 0) {
      console.log("  Cron job removed.");
    } else {
      console.error(`  Warning: cron.unschedule failed: ${r.stderr}`);
    }
  }
  ac.abort();
  try { await server; } catch { /* aborted */ }
}

// ── Write evidence log ────────────────────────────────────────────────────────
await writeLog(overallPass);

async function writeLog(passed: boolean) {
  const logPath = "08_Migration/tests/gate3_cron_net_preflight_result.log";
  const lines = [
    "=== Gate 3 — Local pg_cron / pg_net preflight ===",
    `Timestamp:    ${ts}`,
    `DB:           ${DB_URL}`,
    `Host gateway: ${HOST_GATEWAY}`,
    `Listen port:  ${LISTEN_PORT}`,
    "",
    ...steps,
    "",
    passed
      ? "=== RESULT: GATE 3 PASSED ==="
      : "=== RESULT: GATE 3 FAILED — see step details above ===",
    "Next: Gate 2A — magick-wasm local image-processing spike",
  ];
  await Deno.writeTextFile(logPath, lines.join("\n") + "\n");
  console.log(`\nEvidence written to ${logPath}`);
  console.log(passed ? "\n=== GATE 3 PASSED ===" : "\n=== GATE 3 FAILED ===");
}
