// src/index.test.ts — forkensics-image-spike Rev 10 — full Vitest matrix

import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, it, expect, vi } from "vitest";
import worker from "./index";

const TEST_SECRET = "test-spike-secret";

// ── Types ────────────────────────────────────────────────────────────────────

type MockBucket = {
  head: ReturnType<typeof vi.fn>;
  get:  ReturnType<typeof vi.fn>;
  put:  ReturnType<typeof vi.fn>;
};

type MockImages = {
  info:  ReturnType<typeof vi.fn>;
  input: ReturnType<typeof vi.fn>;
};

type MockEnv = {
  BUCKET:       MockBucket;
  IMAGES:       MockImages;
  SPIKE_SECRET: string;
};

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeStream(bytes: number): ReadableStream<Uint8Array> {
  return new ReadableStream({
    start(controller) {
      controller.enqueue(new Uint8Array(bytes));
      controller.close();
    },
  });
}

function makeOutputChain(body: ReadableStream<Uint8Array>, ct = "image/webp") {
  return {
    transform: vi.fn(() => ({
      output: vi.fn(() => ({
        response: vi.fn(() => new Response(body, { headers: { "Content-Type": ct } })),
      })),
    })),
  };
}

function makeSuccessEnv(): MockEnv {
  return {
    BUCKET: {
      head: vi.fn(async () => ({ etag: "etag-1", size: 500_000 })),
      get:  vi.fn(async () => ({ body: makeStream(100), etag: "etag-1", size: 500_000 })),
      put:  vi.fn(async () => ({ etag: "etag-out", size: 50_000 })),
    },
    IMAGES: {
      info:  vi.fn(async () => ({ format: "image/jpeg", width: 800, height: 600, fileSize: 500_000 })),
      input: vi.fn(() => makeOutputChain(makeStream(100_000))),
    },
    SPIKE_SECRET: TEST_SECRET,
  };
}

async function invoke(
  mockEnv: Partial<MockEnv>,
  path: string,
  headers: Record<string, string> = { Authorization: `Bearer ${TEST_SECRET}` }
): Promise<Response> {
  const env = {
    BUCKET:       mockEnv.BUCKET as unknown as R2Bucket,
    IMAGES:       mockEnv.IMAGES as unknown as ImagesBinding,
    SPIKE_SECRET: mockEnv.SPIKE_SECRET ?? TEST_SECRET,
  } satisfies Env;
  const ctx = createExecutionContext();
  const request = new Request(`https://example.workers.dev${path}`, {
    headers: new Headers(headers),
  });
  const response = await worker.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

// ── §5.1 ETag Race — Read 2 conditional miss → 409 ──────────────────────────

describe("§5.1 ETag race — Read 2 miss", () => {
  it("returns 409 when Read 2 gets metadata-only (no body)", async () => {
    // Read 2: first get() returns no 'body' key → conditional miss
    const mockGet  = vi.fn(async () => ({ etag: "b", size: 500_000 }));
    const mockInfo = vi.fn();
    const mockPut  = vi.fn();
    const resp = await invoke(
      {
        BUCKET: {
          head: vi.fn(async () => ({ etag: "a", size: 500_000 })),
          get:  mockGet,
          put:  mockPut,
        },
        IMAGES: { info: mockInfo, input: vi.fn() },
      },
      "/transform/spike/test.jpg"
    );
    expect(resp.status).toBe(409);
    expect(mockGet).toHaveBeenCalledTimes(1);  // only Read 2 attempted
    expect(mockInfo).not.toHaveBeenCalled();
    expect(mockPut).not.toHaveBeenCalled();
  });
});

// ── §5.2 ETag Race — Read 3 conditional miss → 409 ──────────────────────────

describe("§5.2 ETag race — Read 3 miss", () => {
  it("returns 409 when Read 3 gets metadata-only", async () => {
    let call = 0;
    const mockGet = vi.fn(async () => {
      call++;
      if (call === 1) return { body: new ReadableStream(), etag: "a", size: 500_000 }; // Read 2: has body
      return { etag: "b", size: 500_000 };  // Read 3: no 'body' key → conditional miss
    });
    const mockInfo  = vi.fn(async () => ({ format: "image/jpeg", width: 800, height: 600, fileSize: 500_000 }));
    const mockInput = vi.fn();
    const mockPut   = vi.fn();
    const resp = await invoke(
      {
        BUCKET: {
          head: vi.fn(async () => ({ etag: "a", size: 500_000 })),
          get:  mockGet,
          put:  mockPut,
        },
        IMAGES: { info: mockInfo, input: mockInput },
      },
      "/transform/spike/test.jpg"
    );
    expect(resp.status).toBe(409);
    expect(mockGet).toHaveBeenCalledTimes(2);   // Read 2 + Read 3 both attempted
    expect(mockInfo).toHaveBeenCalledTimes(1);  // Read 2 succeeded → info ran
    expect(mockInput).not.toHaveBeenCalled();
    expect(mockPut).not.toHaveBeenCalled();
  });
});

// ── §5.3 Authorization ───────────────────────────────────────────────────────

describe("§5.3 Authorization", () => {
  it("returns 401 for missing Authorization header", async () => {
    const resp = await invoke(makeSuccessEnv(), "/transform/spike/test.jpg", {});
    expect(resp.status).toBe(401);
  });

  it("returns 401 for wrong token", async () => {
    const resp = await invoke(
      makeSuccessEnv(),
      "/transform/spike/test.jpg",
      { Authorization: "Bearer wrongtoken" }
    );
    expect(resp.status).toBe(401);
  });

  it("returns 200 for /health without Authorization", async () => {
    const resp = await invoke(makeSuccessEnv(), "/health", {});
    expect(resp.status).toBe(200);
  });
});

// ── §5.3b fileSize consistency check ─────────────────────────────────────────

describe("§5.3b fileSize consistency", () => {
  it("returns 409 when info.fileSize does not match head.size", async () => {
    const env = makeSuccessEnv();
    // head.size = 500_000 (from makeSuccessEnv); info.fileSize = 999_999 → mismatch
    env.IMAGES.info = vi.fn(async () => ({
      format: "image/jpeg", width: 800, height: 600, fileSize: 999_999,
    }));
    const resp = await invoke(env, "/transform/spike/test.jpg");
    expect(resp.status).toBe(409);
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });

  it("accepts when info.fileSize matches head.size", async () => {
    const env = makeSuccessEnv();
    // head.size = 500_000; info.fileSize = 500_000 → match
    env.IMAGES.info = vi.fn(async () => ({
      format: "image/jpeg", width: 800, height: 600, fileSize: 500_000,
    }));
    const resp = await invoke(env, "/transform/spike/test.jpg");
    expect(resp.status).toBe(200);
  });

  // Note: ImageInfoResponse discriminated union always has fileSize for non-SVG formats.
  // An SVG response has no width/height/fileSize — the worker returns 422 for SVG via
  // the "width in info" narrowing check, which is covered by the format rejection tests.
});

// ── §5.4 Format aliases and rejection ───────────────────────────────────────

describe("§5.4 Format aliases", () => {
  for (const alias of ["jpeg", "jpg", "image/jpeg", "webp", "image/webp"]) {
    it(`accepts format alias "${alias}"`, async () => {
      const env = makeSuccessEnv();
      // fileSize must match head.size (500_000) to pass consistency check
      env.IMAGES.info = vi.fn(async () => ({ format: alias, width: 800, height: 600, fileSize: 500_000 }));
      const resp = await invoke(env, "/transform/spike/test.jpg");
      expect(resp.status).toBe(200);
    });
  }

  for (const fmt of ["png", "image/png", "heic", "avif", "gif", "tiff"]) {
    it(`rejects format "${fmt}" with 422`, async () => {
      const env = makeSuccessEnv();
      env.IMAGES.info = vi.fn(async () => ({ format: fmt, width: 800, height: 600, fileSize: 500_000 }));
      const resp = await invoke(env, "/transform/spike/test.jpg");
      expect(resp.status).toBe(422);
    });

    it(`does not call BUCKET.put() for format "${fmt}"`, async () => {
      const env = makeSuccessEnv();
      env.IMAGES.info = vi.fn(async () => ({ format: fmt, width: 800, height: 600, fileSize: 500_000 }));
      await invoke(env, "/transform/spike/test.jpg");
      expect(env.BUCKET.put).not.toHaveBeenCalled();
    });
  }
});

// ── §5.5 Size boundary ───────────────────────────────────────────────────────

describe("§5.5 Size boundary", () => {
  it("accepts input at exactly 10,485,760 bytes (10 MB)", async () => {
    const env = makeSuccessEnv();
    env.BUCKET.head = vi.fn(async () => ({ etag: "etag-1", size: 10_485_760 }));
    // info.fileSize must match head.size to pass the consistency check
    env.IMAGES.info = vi.fn(async () => ({ format: "image/jpeg", width: 800, height: 600, fileSize: 10_485_760 }));
    const resp = await invoke(env, "/transform/spike/test.jpg");
    expect(resp.status).toBe(200);
  });

  it("rejects input at 10,485,761 bytes (10 MB + 1)", async () => {
    const env = makeSuccessEnv();
    env.BUCKET.head = vi.fn(async () => ({ etag: "etag-1", size: 10_485_761 }));
    const resp = await invoke(env, "/transform/spike/test.jpg");
    expect(resp.status).toBe(422);
  });

  it("does not call BUCKET.put() for oversized input", async () => {
    const env = makeSuccessEnv();
    env.BUCKET.head = vi.fn(async () => ({ etag: "etag-1", size: 10_485_761 }));
    await invoke(env, "/transform/spike/test.jpg");
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });
});

// ── §5.6 Pixel area boundary ─────────────────────────────────────────────────

describe("§5.6 Pixel area boundary", () => {
  // 3100 × 5000 = 15,500,000 (exactly at ceiling — PASS)
  it("accepts image at exactly 15,500,000 pixels (3100×5000)", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.info = vi.fn(async () => ({ format: "image/jpeg", width: 3100, height: 5000, fileSize: 500_000 }));
    const resp = await invoke(env, "/transform/spike/test.jpg");
    expect(resp.status).toBe(200);
  });

  // 2739 × 5659 = 15,500,001 (one over — FAIL)
  it("rejects image at 15,500,001 pixels (2739×5659)", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.info = vi.fn(async () => ({ format: "image/jpeg", width: 2739, height: 5659, fileSize: 500_000 }));
    const resp = await invoke(env, "/transform/spike/test.jpg");
    expect(resp.status).toBe(422);
  });

  it("does not call BUCKET.put() for over-area input", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.info = vi.fn(async () => ({ format: "image/jpeg", width: 2739, height: 5659, fileSize: 500_000 }));
    await invoke(env, "/transform/spike/test.jpg");
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });
});

// ── §5.7 Output size boundary ─────────────────────────────────────────────────

describe("§5.7 Output size boundary", () => {
  it("rejects transform output at 5,242,881 bytes (5 MB + 1)", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.input = vi.fn(() => makeOutputChain(makeStream(5_242_881)));
    const resp = await invoke(env, "/transform/spike/test.jpg");
    expect(resp.status).toBe(422);
  });

  it("does not call BUCKET.put() for over-ceiling output", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.input = vi.fn(() => makeOutputChain(makeStream(5_242_881)));
    await invoke(env, "/transform/spike/test.jpg");
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });

  it("accepts transform output at exactly 5,242,880 bytes", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.input = vi.fn(() => makeOutputChain(makeStream(5_242_880)));
    const resp = await invoke(env, "/transform/spike/test.jpg");
    expect(resp.status).toBe(200);
  });
});

// ── §5.8 Transform failure ────────────────────────────────────────────────────

describe("§5.8 Transform failure", () => {
  it("returns 500 when IMAGES.input() throws", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.input = vi.fn(() => { throw new Error("transform failed"); });
    const resp = await invoke(env, "/transform/spike/test.jpg");
    expect(resp.status).toBe(500);
  });

  it("does not call BUCKET.put() when transform throws", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.input = vi.fn(() => { throw new Error("transform failed"); });
    await invoke(env, "/transform/spike/test.jpg");
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });

  it("returns 502 when transform returns non-OK status", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.input = vi.fn(() => ({
      transform: vi.fn(() => ({
        output: vi.fn(() => ({
          response: vi.fn(() =>
            new Response("error", {
              status: 400,
              headers: { "Content-Type": "image/webp" },
            })
          ),
        })),
      })),
    }));
    const resp = await invoke(env, "/transform/spike/test.jpg");
    expect(resp.status).toBe(502);
  });

  it("returns 502 when transform returns wrong Content-Type", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.input = vi.fn(() => makeOutputChain(makeStream(100), "image/png"));
    const resp = await invoke(env, "/transform/spike/test.jpg");
    expect(resp.status).toBe(502);
  });
});

// ── §5.9 No-write guarantees ─────────────────────────────────────────────────

describe("§5.9 No-write guarantees", () => {
  it("does not call BUCKET.put() on 401 (no auth)", async () => {
    const env = makeSuccessEnv();
    await invoke(env, "/transform/spike/test.jpg", {});
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });

  it("does not call BUCKET.put() on 400 (bad key — path traversal)", async () => {
    const env = makeSuccessEnv();
    await invoke(env, "/transform/../etc/passwd");
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });

  it("does not call BUCKET.put() on 404 (missing object)", async () => {
    const env = makeSuccessEnv();
    env.BUCKET.head = vi.fn(async () => null);
    await invoke(env, "/transform/spike/missing.jpg");
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });

  it("does not call BUCKET.put() on 409 (Read 2 ETag miss)", async () => {
    const env = makeSuccessEnv();
    env.BUCKET.get = vi.fn(async () => ({ etag: "b", size: 500_000 }));
    await invoke(env, "/transform/spike/test.jpg");
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });

  it("does not call BUCKET.put() on 409 (fileSize mismatch)", async () => {
    const env = makeSuccessEnv();
    // head.size = 500_000; info.fileSize = 999_999 → mismatch → 409
    env.IMAGES.info = vi.fn(async () => ({
      format: "image/jpeg", width: 800, height: 600, fileSize: 999_999,
    }));
    await invoke(env, "/transform/spike/test.jpg");
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });

  it("does not call BUCKET.put() on 422 (input too large)", async () => {
    const env = makeSuccessEnv();
    env.BUCKET.head = vi.fn(async () => ({ etag: "etag-1", size: 10_485_761 }));
    await invoke(env, "/transform/spike/test.jpg");
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });

  it("does not call BUCKET.put() on 422 (rejected format)", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.info = vi.fn(async () => ({ format: "image/png", width: 800, height: 600 }));
    await invoke(env, "/transform/spike/test.jpg");
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });

  it("does not call BUCKET.put() on 422 (pixel area exceeded)", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.info = vi.fn(async () => ({ format: "image/jpeg", width: 2739, height: 5659 }));
    await invoke(env, "/transform/spike/test.jpg");
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });

  it("does not call BUCKET.put() on 422 (output too large)", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.input = vi.fn(() => makeOutputChain(makeStream(5_242_881)));
    await invoke(env, "/transform/spike/test.jpg");
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });

  it("does not call BUCKET.put() on 500 (transform throws)", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.input = vi.fn(() => { throw new Error("boom"); });
    await invoke(env, "/transform/spike/test.jpg");
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });

  it("does not call BUCKET.put() on 502 (transform non-OK)", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.input = vi.fn(() => ({
      transform: vi.fn(() => ({
        output: vi.fn(() => ({
          response: vi.fn(() =>
            new Response("error", {
              status: 503,
              headers: { "Content-Type": "image/webp" },
            })
          ),
        })),
      })),
    }));
    await invoke(env, "/transform/spike/test.jpg");
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });

  it("does not call BUCKET.put() on 502 (wrong Content-Type)", async () => {
    const env = makeSuccessEnv();
    env.IMAGES.input = vi.fn(() => makeOutputChain(makeStream(100), "image/png"));
    await invoke(env, "/transform/spike/test.jpg");
    expect(env.BUCKET.put).not.toHaveBeenCalled();
  });
});
