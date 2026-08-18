/**
 * Gate 4 — Local S3 preflight (Supabase Storage S3-compatible)
 *
 * Verifies that S3 Signature V4 presigned PUT works against the local
 * Supabase stack before any Edge Function TypeScript is written.
 *
 * Usage (from WhatAndWhere/):
 *   S3_ACCESS_KEY_ID=<id> S3_SECRET_ACCESS_KEY=<secret> SUPABASE_SERVICE_ROLE_KEY=<key> \
 *     deno run --allow-net --allow-env --allow-write \
 *     --allow-read=/Users/billschroeder/.aws --allow-sys=osRelease \
 *     tools/gate4_s3_preflight.ts
 *
 * Credentials come from: supabase status -o env
 *   S3_PROTOCOL_ACCESS_KEY_ID     → S3_ACCESS_KEY_ID
 *   S3_PROTOCOL_ACCESS_KEY_SECRET → S3_SECRET_ACCESS_KEY
 *   SERVICE_ROLE_KEY              → SUPABASE_SERVICE_ROLE_KEY
 *
 * NEVER hardcode credentials here. NEVER commit credentials to the repo.
 */

import {
  DeleteObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  S3Client,
} from "npm:@aws-sdk/client-s3";
import { getSignedUrl } from "npm:@aws-sdk/s3-request-presigner";

// ── Config ────────────────────────────────────────────────────────────────────
const ENDPOINT = "http://127.0.0.1:54321/storage/v1/s3";
const REGION = "local";
const BUCKET = "game-media";
const KEY = "preflight-test/object.bin";
const EXPIRES_IN = 300; // only permitted value per Step 27 Rev 5

// ── Credentials (env only — never hardcoded) ──────────────────────────────────
const accessKeyId = Deno.env.get("S3_ACCESS_KEY_ID");
const secretAccessKey = Deno.env.get("S3_SECRET_ACCESS_KEY");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!accessKeyId || !secretAccessKey || !serviceRoleKey) {
  console.error(
    "ERROR: S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, and SUPABASE_SERVICE_ROLE_KEY are required.\n" +
      "Obtain from: supabase status -o env\n" +
      "  S3_PROTOCOL_ACCESS_KEY_ID     → S3_ACCESS_KEY_ID\n" +
      "  S3_PROTOCOL_ACCESS_KEY_SECRET → S3_SECRET_ACCESS_KEY\n" +
      "  SERVICE_ROLE_KEY              → SUPABASE_SERVICE_ROLE_KEY",
  );
  Deno.exit(1);
}

// ── Client ────────────────────────────────────────────────────────────────────
const client = new S3Client({
  endpoint: ENDPOINT,
  region: REGION,
  credentials: { accessKeyId, secretAccessKey },
  forcePathStyle: true, // required for Supabase Storage S3 API
});

// ── Storage REST base (for bucket operations) ─────────────────────────────────
const STORAGE_URL = "http://127.0.0.1:54321/storage/v1";

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

// ── Step 0: Ensure bucket exists (idempotent create) ─────────────────────────
console.log("\nStep 0 — Ensure bucket exists (idempotent create)");
try {
  const resp = await fetch(`${STORAGE_URL}/bucket`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${serviceRoleKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ id: BUCKET, name: BUCKET, public: false }),
  });
  if (resp.ok) {
    pass("Step 0", `bucket created (HTTP ${resp.status})`);
  } else {
    const body = await resp.text();
    // 409 Duplicate = already exists; that's fine
    if (resp.status === 409 || body.includes("already exists") || body.includes("Duplicate")) {
      pass("Step 0", "bucket already exists");
    } else {
      fail("Step 0", `HTTP ${resp.status} — ${body}`);
      await writeLog(false);
      Deno.exit(1);
    }
  }
} catch (err) {
  fail("Step 0", err);
  await writeLog(false);
  Deno.exit(1);
}

// ── Step 1: Generate presigned PUT URL ────────────────────────────────────────
console.log("\nStep 1 — Generate presigned PUT URL (ExpiresIn: 300)");
let presignedUrl = "";
try {
  const cmd = new PutObjectCommand({
    Bucket: BUCKET,
    Key: KEY,
    ContentLength: 0,
  });
  presignedUrl = await getSignedUrl(client, cmd, { expiresIn: EXPIRES_IN });
  // Log only the path portion — never log the full signed URL with credentials
  const urlObj = new URL(presignedUrl);
  pass("Step 1", `signed — ${urlObj.origin}${urlObj.pathname}`);
} catch (err) {
  fail("Step 1", err);
  await writeLog(false);
  Deno.exit(1);
}

// ── Step 2: Upload zero-byte body via presigned PUT ───────────────────────────
console.log("\nStep 2 — Upload zero-byte object via presigned PUT");
try {
  const resp = await fetch(presignedUrl, {
    method: "PUT",
    body: new Uint8Array(0),
    headers: { "Content-Length": "0" },
  });
  const body = await resp.text();
  if (resp.ok) {
    pass("Step 2", `HTTP ${resp.status}`);
  } else {
    fail("Step 2", `HTTP ${resp.status} — ${body}`);
    await writeLog(false);
    Deno.exit(1);
  }
} catch (err) {
  fail("Step 2", err);
  await writeLog(false);
  Deno.exit(1);
}

// ── Step 3: Confirm object exists via HeadObject ──────────────────────────────
console.log("\nStep 3 — Confirm object exists (HeadObject)");
try {
  const head = await client.send(
    new HeadObjectCommand({ Bucket: BUCKET, Key: KEY }),
  );
  pass("Step 3", `ETag: ${head.ETag ?? "n/a"}, ContentLength: ${head.ContentLength}`);
} catch (err) {
  fail("Step 3", err);
  await writeLog(false);
  Deno.exit(1);
}

// ── Step 4: Delete object ─────────────────────────────────────────────────────
console.log("\nStep 4 — Delete object");
try {
  await client.send(new DeleteObjectCommand({ Bucket: BUCKET, Key: KEY }));
  pass("Step 4", "object deleted");
} catch (err) {
  fail("Step 4", err);
}

// ── Write evidence log ────────────────────────────────────────────────────────
await writeLog(overallPass);

async function writeLog(passed: boolean) {
  const logPath = "08_Migration/tests/gate4_s3_preflight_result.log";
  const lines = [
    "=== Gate 4 — Local S3 preflight ===",
    `Timestamp:  ${ts}`,
    `Endpoint:   ${ENDPOINT}`,
    `Region:     ${REGION}`,
    `Bucket/Key: ${BUCKET}/${KEY}`,
    `ExpiresIn:  ${EXPIRES_IN}`,
    "",
    ...steps,
    "",
    passed
      ? "=== RESULT: GATE 4 PASSED ==="
      : "=== RESULT: GATE 4 FAILED — see step details above ===",
    "Next: Gate 3 — local pg_cron/pg_net preflight",
  ];
  await Deno.writeTextFile(logPath, lines.join("\n") + "\n");
  console.log(`\nEvidence written to ${logPath}`);
  if (passed) {
    console.log("\n=== GATE 4 PASSED ===");
  } else {
    console.error("\n=== GATE 4 FAILED ===");
  }
}
