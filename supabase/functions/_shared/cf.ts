// cf.ts — Cloudflare image-transform Worker client
// Reads CF_ACCESS_CLIENT_ID, CF_ACCESS_CLIENT_SECRET, CF_WORKER_URL from env.
// Never logs credential values.

import type { FkErrorCode } from "./errors.ts";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const APPROVED_HOSTNAME = "forkensics-image-transform-dev.billmags.workers.dev";
const TIMEOUT_MS = 50_000; // 50 s — below 60 s Edge Function wall-clock limit
const MAX_BODY_BYTES = 4_096;
const SHA256_RE = /^[0-9a-f]{64}$/;
const MAX_OUTPUT_BYTES = 5_242_880; // 5 MiB

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type CfTransformResult =
  | { ok: true; displayKey: string; sha256: string; bytes: number }
  | { ok: false; fkCode: FkErrorCode; workerStatus: number };

// ---------------------------------------------------------------------------
// URL validation
// ---------------------------------------------------------------------------

/**
 * Validates CF_WORKER_URL at call time.
 * All rules are fail-closed: any failure returns null → FK_INTERNAL.
 * Prevents credential forwarding to an arbitrary HTTPS host on misconfiguration.
 */
function validateWorkerUrl(raw: string): URL | null {
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    return null;
  }
  if (parsed.protocol !== "https:") return null;
  if (parsed.hostname !== APPROVED_HOSTNAME) return null;
  if (parsed.pathname !== "" && parsed.pathname !== "/") return null;
  if (parsed.username !== "") return null;
  if (parsed.password !== "") return null;
  if (parsed.search !== "") return null;
  if (parsed.hash !== "") return null;
  return parsed;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Calls the Cloudflare image-transform Worker for the given media UUID.
 *
 * Contract:
 *   - Validates CF_ACCESS_CLIENT_ID, CF_ACCESS_CLIENT_SECRET, CF_WORKER_URL
 *     at call time. Missing or empty → ok: false, fkCode: "FK_INTERNAL".
 *   - Pins to APPROVED_HOSTNAME; any mismatch → ok: false, fkCode: "FK_INTERNAL".
 *   - 50-second AbortController timeout. AbortError treated same as fetch throw.
 *   - Reads at most MAX_BODY_BYTES from the 200 response body.
 *   - Validates displayKey, sha256, and bytes on 200.
 *   - Never logs CF_ACCESS_CLIENT_ID or CF_ACCESS_CLIENT_SECRET.
 *   - Never throws.
 */
export async function callImageTransform(
  mediaUuid: string,
): Promise<CfTransformResult> {
  // ── Env validation ────────────────────────────────────────────────────────
  const clientId = Deno.env.get("CF_ACCESS_CLIENT_ID") ?? "";
  const clientSecret = Deno.env.get("CF_ACCESS_CLIENT_SECRET") ?? "";
  const workerUrlRaw = Deno.env.get("CF_WORKER_URL") ?? "";

  if (!clientId || !clientSecret || !workerUrlRaw) {
    return { ok: false, fkCode: "FK_INTERNAL", workerStatus: 0 };
  }

  // ── URL validation ────────────────────────────────────────────────────────
  if (!validateWorkerUrl(workerUrlRaw)) {
    return { ok: false, fkCode: "FK_INTERNAL", workerStatus: 0 };
  }

  const endpoint =
    `https://${APPROVED_HOSTNAME}/transform/originals/${mediaUuid}`;

  // ── HTTP request with AbortController timeout ─────────────────────────────
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  let res: Response;
  try {
    res = await fetch(endpoint, {
      method: "POST",
      headers: {
        "CF-Access-Client-Id": clientId,
        "CF-Access-Client-Secret": clientSecret,
        "Content-Type": "application/json",
      },
      body: "{}",
      signal: controller.signal,
    });
  } catch {
    // Covers fetch throws (network error) and AbortError (timeout)
    return { ok: false, fkCode: "FK_INTERNAL", workerStatus: 0 };
  } finally {
    clearTimeout(timer);
  }

  const status = res.status;

  // ── Status mapping ────────────────────────────────────────────────────────
  if (status === 404) {
    await res.body?.cancel();
    return { ok: false, fkCode: "FK_NOT_FOUND", workerStatus: status };
  }
  if (status === 422) {
    await res.body?.cancel();
    return { ok: false, fkCode: "FK_PROCESSING_FAILED", workerStatus: status };
  }
  if (status !== 200) {
    await res.body?.cancel();
    return { ok: false, fkCode: "FK_INTERNAL", workerStatus: status };
  }

  // ── Bounded body read (200 only) ──────────────────────────────────────────
  let bodyText: string;
  try {
    const reader = res.body?.getReader();
    if (!reader) {
      return { ok: false, fkCode: "FK_INTERNAL", workerStatus: status };
    }
    const chunks: Uint8Array[] = [];
    let totalBytes = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > MAX_BODY_BYTES) {
        await reader.cancel();
        return { ok: false, fkCode: "FK_INTERNAL", workerStatus: status };
      }
      chunks.push(value);
    }
    const merged = new Uint8Array(totalBytes);
    let offset = 0;
    for (const chunk of chunks) {
      merged.set(chunk, offset);
      offset += chunk.byteLength;
    }
    bodyText = new TextDecoder().decode(merged);
  } catch {
    return { ok: false, fkCode: "FK_INTERNAL", workerStatus: status };
  }

  // ── Response body validation ──────────────────────────────────────────────
  let parsed: unknown;
  try {
    parsed = JSON.parse(bodyText);
  } catch {
    return { ok: false, fkCode: "FK_INTERNAL", workerStatus: status };
  }
  if (!parsed || typeof parsed !== "object") {
    return { ok: false, fkCode: "FK_INTERNAL", workerStatus: status };
  }
  const obj = parsed as Record<string, unknown>;

  const displayKey = obj["displayKey"];
  const sha256 = obj["sha256"];
  const bytes = obj["bytes"];

  if (typeof displayKey !== "string" || displayKey === "") {
    return { ok: false, fkCode: "FK_INTERNAL", workerStatus: status };
  }
  if (typeof sha256 !== "string" || !SHA256_RE.test(sha256)) {
    return { ok: false, fkCode: "FK_INTERNAL", workerStatus: status };
  }
  if (
    typeof bytes !== "number" ||
    !Number.isInteger(bytes) ||
    bytes <= 0 ||
    bytes > MAX_OUTPUT_BYTES
  ) {
    return { ok: false, fkCode: "FK_INTERNAL", workerStatus: status };
  }

  return { ok: true, displayKey, sha256, bytes };
}
