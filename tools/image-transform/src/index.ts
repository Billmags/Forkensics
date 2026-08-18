// src/index.ts — forkensics-image-transform Production Rev 2 — 2026-08-16
// Auth: Cloudflare Access service token enforced at CF edge — no auth code in Worker
// Key convention: R2 original at "originals/{media_id}" → display at "display/{media_id}.webp"
// Response: JSON metadata; image bytes not returned to caller

const FORMAT_ALIAS_MAP: Record<string, string> = {
  "jpg":        "image/jpeg",
  "jpeg":       "image/jpeg",
  "image/jpeg": "image/jpeg",
  "webp":       "image/webp",
  "image/webp": "image/webp",
};
const ACCEPTED_FORMATS  = new Set(["image/jpeg", "image/webp"]);
const MAX_INPUT_BYTES   = 10 * 1024 * 1024;  // 10 MB
const MAX_OUTPUT_BYTES  =  5 * 1024 * 1024;  //  5 MB output ceiling
const MAX_PIXELS        = 15_500_000;         // 15.5 MP area gate
const MAX_DIMENSION_PX  = 8_192;              // px per side gate

// Canonical UUID v4 pattern (lowercase)
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function jsonError(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export default {
  async fetch(
    request: Request,
    env: Env,
    _ctx: ExecutionContext,
  ): Promise<Response> {
    const url = new URL(request.url);

    // Health check — protected by CF Access (same as all other paths)
    if (url.pathname === "/health") {
      return new Response(JSON.stringify({ status: "ok" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Only POST is accepted for the transform endpoint
    if (request.method !== "POST") {
      return new Response(null, {
        status: 405,
        headers: { Allow: "POST" },
      });
    }

    // Key extraction and strict validation
    // Path must be: /transform/originals/{canonical-UUID}
    const pathMatch = url.pathname.match(/^\/transform\/(originals\/[^/]+)$/);
    if (!pathMatch) {
      return jsonError(400, "Path must be /transform/originals/{uuid}");
    }
    const key = pathMatch[1]; // "originals/{uuid}"
    const mediaId = key.split("/")[1];
    if (!UUID_RE.test(mediaId)) {
      return jsonError(400, "Key must be a canonical lowercase UUID v4");
    }

    // ── Read 1: HEAD — byte-size gate, no body stream opened ─────────────────
    const head = await env.BUCKET.head(key);
    if (!head) return jsonError(404, "Not found");
    const etag = head.etag;

    if (head.size > MAX_INPUT_BYTES) {
      return jsonError(422, `Input too large: ${head.size} > ${MAX_INPUT_BYTES}`);
    }

    // ── Read 2: conditional GET → IMAGES.info() ───────────────────────────────
    // IMAGES.info() is documented as free (not metered against transform quota).
    // Decode behavior is not specified by Cloudflare; no claim is made here.
    const infoObject = await env.BUCKET.get(key, {
      onlyIf: { etagMatches: etag },
    });
    if (!infoObject || !("body" in infoObject) || !infoObject.body) {
      return jsonError(409, "Input changed between reads");
    }

    const info = await env.IMAGES.info(infoObject.body);

    // SVG branch of the discriminated union has no width/height — narrow before use
    if (!("width" in info)) {
      return jsonError(422, `Unsupported format: ${info.format}`);
    }

    // Format gate
    const normalizedFormat =
      FORMAT_ALIAS_MAP[String(info.format).toLowerCase()] ?? null;
    if (!normalizedFormat || !ACCEPTED_FORMATS.has(normalizedFormat)) {
      return jsonError(422, `Unsupported format: ${info.format}`);
    }

    // Per-side dimension gate (OQ-4)
    if (info.width > MAX_DIMENSION_PX || info.height > MAX_DIMENSION_PX) {
      return jsonError(
        422,
        `Dimension ${info.width}×${info.height} exceeds ${MAX_DIMENSION_PX}px per-side limit`,
      );
    }

    // Area gate (OQ-4)
    if (info.width * info.height > MAX_PIXELS) {
      return jsonError(
        422,
        `Pixel area ${info.width * info.height} > ${MAX_PIXELS}`,
      );
    }

    // ETag consistency
    if (info.fileSize !== head.size) {
      return jsonError(
        409,
        `File size mismatch: head=${head.size} info.fileSize=${info.fileSize}`,
      );
    }

    // ── Read 3: conditional GET → transform ──────────────────────────────────
    const transformObject = await env.BUCKET.get(key, {
      onlyIf: { etagMatches: etag },
    });
    if (!transformObject || !("body" in transformObject) || !transformObject.body) {
      return jsonError(409, "Input changed between reads");
    }

    let transformResponse: Response;
    try {
      transformResponse = (
        await env.IMAGES.input(transformObject.body)
          .transform({ width: 1280, height: 1280, fit: "scale-down" })
          .output({ format: "image/webp", quality: 85, anim: false })
      ).response();
    } catch (err) {
      return jsonError(500, `Transform error: ${err}`);
    }

    if (!transformResponse.ok) {
      return jsonError(502, `Transform non-OK: ${transformResponse.status}`);
    }

    const ct = (transformResponse.headers.get("Content-Type") ?? "")
      .split(";")[0]
      .trim();
    if (ct !== "image/webp") {
      return jsonError(502, `Unexpected Content-Type: ${ct}`);
    }
    if (!transformResponse.body) {
      return jsonError(502, "Empty transform body");
    }

    // ── Bounded stream read ───────────────────────────────────────────────────
    const reader = transformResponse.body.getReader();
    const chunks: Uint8Array[] = [];
    let totalBytes = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > MAX_OUTPUT_BYTES) {
        await reader.cancel();
        return jsonError(422, "Output exceeds ceiling");
      }
      chunks.push(value);
    }
    if (totalBytes === 0) return jsonError(502, "Empty output");

    const out = new Uint8Array(totalBytes);
    let off = 0;
    for (const c of chunks) {
      out.set(c, off);
      off += c.byteLength;
    }

    // SHA-256 of output bytes
    const hashHex = Array.from(
      new Uint8Array(await crypto.subtle.digest("SHA-256", out)),
    )
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    // Display key: "display/{media_id}.webp"
    const displayKey = `display/${mediaId}.webp`;

    await env.BUCKET.put(displayKey, out, {
      httpMetadata: { contentType: "image/webp" },
    });

    return new Response(
      JSON.stringify({ displayKey, sha256: hashHex, bytes: totalBytes }),
      {
        status: 200,
        headers: { "Content-Type": "application/json" },
      },
    );
  },
} satisfies ExportedHandler<Env>;
