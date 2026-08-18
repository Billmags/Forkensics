// src/index.ts — forkensics-image-spike Rev 10 — SPIKE ONLY

const FORMAT_ALIAS_MAP: Record<string, string> = {
  "jpg":        "image/jpeg",
  "jpeg":       "image/jpeg",
  "image/jpeg": "image/jpeg",
  "webp":       "image/webp",
  "image/webp": "image/webp",
};
const ACCEPTED_FORMATS = new Set(["image/jpeg", "image/webp"]);
const MAX_INPUT_BYTES  = 10 * 1024 * 1024;
const MAX_OUTPUT_BYTES =  5 * 1024 * 1024;
const MAX_PIXELS       = 15_500_000;

export default {
  async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/health") return new Response("ok", { status: 200 });

    if (request.headers.get("Authorization") !== `Bearer ${env.SPIKE_SECRET}`) {
      return new Response("Unauthorized", { status: 401 });
    }

    const key = url.pathname.replace(/^\/transform\//, "").trim();
    if (!key || key.includes("..") || key.startsWith("/")) {
      return new Response("Invalid key", { status: 400 });
    }

    // Read 1: head-only — no body stream opened
    const head = await env.BUCKET.head(key);
    if (!head) return new Response("Not found", { status: 404 });
    const etag = head.etag;
    if (head.size > MAX_INPUT_BYTES) {
      return new Response(`Input too large: ${head.size}`, { status: 422 });
    }

    // Read 2: conditional get → info (free)
    const infoObject = await env.BUCKET.get(key, { onlyIf: { etagMatches: etag } });
    if (!infoObject || !("body" in infoObject) || !infoObject.body) {
      return new Response("Input changed between reads", { status: 409 });
    }
    // Use inferred type from generated Env — no `as` assertion
    const info = await env.IMAGES.info(infoObject.body);
    console.log(`info.format raw: ${JSON.stringify(info.format)}`);

    // ImageInfoResponse is a discriminated union: the SVG branch has no width/height/fileSize.
    // Narrow to the non-SVG branch before accessing those fields.
    if (!("width" in info)) {
      return new Response(`Unsupported format: ${info.format}`, { status: 422 });
    }
    // After narrowing: info.format, info.width, info.height, info.fileSize are all present.

    const normalizedFormat = FORMAT_ALIAS_MAP[String(info.format).toLowerCase()] ?? null;
    if (!normalizedFormat || !ACCEPTED_FORMATS.has(normalizedFormat)) {
      return new Response(`Unsupported format: ${info.format}`, { status: 422 });
    }
    if (info.width * info.height > MAX_PIXELS) {
      return new Response(`Pixel area ${info.width * info.height} > ${MAX_PIXELS}`, { status: 422 });
    }
    // fileSize consistency: always present in non-SVG branch — no cast needed.
    // Mismatch means the object changed between reads; treat as ETag race.
    if (info.fileSize !== head.size) {
      return new Response(
        `File size mismatch: head=${head.size} info.fileSize=${info.fileSize}`,
        { status: 409 }
      );
    }

    // Read 3: conditional get → transform
    const transformObject = await env.BUCKET.get(key, { onlyIf: { etagMatches: etag } });
    if (!transformObject || !("body" in transformObject) || !transformObject.body) {
      return new Response("Input changed between reads", { status: 409 });
    }

    let transformResponse: Response;
    try {
      transformResponse = (
        await env.IMAGES.input(transformObject.body)
          .transform({ width: 1280, height: 1280, fit: "scale-down" })
          .output({ format: "image/webp", quality: 85, anim: false })
      ).response();
    } catch (err) {
      return new Response(`Transform error: ${err}`, { status: 500 });
    }

    if (!transformResponse.ok) {
      return new Response(`Transform non-OK: ${transformResponse.status}`, { status: 502 });
    }
    const ct = (transformResponse.headers.get("Content-Type") ?? "").split(";")[0].trim();
    if (ct !== "image/webp") {
      return new Response(`Unexpected Content-Type: ${ct}`, { status: 502 });
    }
    if (!transformResponse.body) return new Response("Empty body", { status: 502 });

    // Bounded stream read
    const reader = transformResponse.body.getReader();
    const chunks: Uint8Array[] = [];
    let totalBytes = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > MAX_OUTPUT_BYTES) {
        await reader.cancel();
        return new Response("Output exceeds ceiling", { status: 422 });
      }
      chunks.push(value);
    }
    if (totalBytes === 0) return new Response("Empty output", { status: 502 });
    const out = new Uint8Array(totalBytes);
    let off = 0;
    for (const c of chunks) { out.set(c, off); off += c.byteLength; }

    const hashHex = Array.from(
      new Uint8Array(await crypto.subtle.digest("SHA-256", out))
    ).map((b) => b.toString(16).padStart(2, "0")).join("");

    const displayKey = `display/${key.split("/").pop()!}.webp`;
    await env.BUCKET.put(displayKey, out, { httpMetadata: { contentType: "image/webp" } });

    return new Response(out, {
      status: 200,
      headers: {
        "Content-Type":             "image/webp",
        "X-Forkensics-SHA256":      hashHex,
        "X-Forkensics-Display-Key": displayKey,
        "X-Forkensics-Size":        String(totalBytes),
      },
    });
  },
} satisfies ExportedHandler<Env>;
