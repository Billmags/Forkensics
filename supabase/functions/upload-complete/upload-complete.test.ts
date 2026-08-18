/**
 * Unit tests for upload-complete.
 * All external calls are stubbed via the Deps interface.
 *
 * Run with:
 *   deno test --allow-env \
 *     supabase/functions/upload-complete/upload-complete.test.ts
 */
import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.112.3";
import { makeHandler } from "./index.ts";
import type { Deps } from "./index.ts";
import type { CfTransformResult } from "../_shared/cf.ts";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const SESSION_ID = "00000000-0000-0000-0000-000000000010";
const USER_ID = "00000000-0000-0000-0000-000000000002";
const UPLOAD_TOKEN = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const TOKEN_HASH = "a".repeat(64);
const ORIG_PATH = `originals/${SESSION_ID}`;
const DISP_PATH = `display/${SESSION_ID}.webp`;
const VALID_SHA256 = "b".repeat(64);
const MEDIA_OBJECT_ID = "00000000-0000-0000-0000-000000000020";

// Minimal valid WebP bytes (RIFF....WEBP)
function makeWebPBytes(): Uint8Array {
  const buf = new Uint8Array(12);
  buf[0] = 0x52;
  buf[1] = 0x49;
  buf[2] = 0x46;
  buf[3] = 0x46; // RIFF
  buf[4] = 0x04;
  buf[5] = 0x00;
  buf[6] = 0x00;
  buf[7] = 0x00; // size
  buf[8] = 0x57;
  buf[9] = 0x45;
  buf[10] = 0x42;
  buf[11] = 0x50; // WEBP
  return buf;
}

function makeRequest(
  body: Record<string, unknown> = { upload_token: UPLOAD_TOKEN },
): Request {
  return new Request("https://example.com/upload-complete", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function makeSession(
  overrides: Partial<{
    status: string;
    media_object_id: string | null;
    replaced_media_object_id: string | null;
  }> = {},
): {
  session_id: string;
  status: string;
  original_storage_path: string;
  display_storage_path: string;
  content_type: string;
  storage_upload_expires_at: string | null;
  processing_lease_expires_at: string | null;
  media_object_id: string | null;
  replaced_media_object_id: string | null;
} {
  return {
    session_id: SESSION_ID,
    status: "pending",
    original_storage_path: ORIG_PATH,
    display_storage_path: DISP_PATH,
    content_type: "image/jpeg",
    storage_upload_expires_at: new Date(Date.now() + 300_000).toISOString(),
    processing_lease_expires_at: null,
    media_object_id: null,
    replaced_media_object_id: null,
    ...overrides,
  };
}

function makeOkAuth(userId = USER_ID) {
  return {
    ok: true as const,
    ctx: {
      userClaims: { id: userId },
      supabase: {} as SupabaseClient,
      supabaseAdmin: {} as SupabaseClient,
    },
    error: null,
  };
}

function makeUnauthResult() {
  return {
    ok: false as const,
    ctx: null,
    error: new Response(
      JSON.stringify({
        error: { code: "FK_UNAUTHENTICATED", message: "Unauthorized" },
      }),
      {
        status: 401,
        headers: {
          "Content-Type": "application/json",
          "Cache-Control": "no-store",
        },
      },
    ),
  };
}

function okCfResult(): CfTransformResult {
  return {
    ok: true,
    displayKey: DISP_PATH,
    sha256: VALID_SHA256,
    bytes: 1024,
  };
}

function failCfResult(
  fkCode: "FK_NOT_FOUND" | "FK_PROCESSING_FAILED" | "FK_INTERNAL",
): CfTransformResult {
  return {
    ok: false,
    fkCode,
    workerStatus: fkCode === "FK_NOT_FOUND"
      ? 404
      : fkCode === "FK_PROCESSING_FAILED"
      ? 422
      : 500,
  };
}

/** Build minimal valid Deps; individual tests override specific methods. */
function makeDeps(overrides: Partial<Deps> = {}): Deps {
  return {
    getAuth: () => Promise.resolve(makeOkAuth()),
    sha256: (_data) => Promise.resolve(TOKEN_HASH),
    resolveSession: (_admin, _hash, _uid) =>
      Promise.resolve({ data: makeSession(), error: null }),
    advanceProcessing: (_admin, _sid, _uid) => Promise.resolve({ error: null }),
    checkLease: (_admin, _sid) => Promise.resolve({ data: true, error: null }),
    advanceSanitized: (_admin, _sid) => Promise.resolve({ error: null }),
    finalizeSession: (_admin, _sid, _hash) =>
      Promise.resolve({
        data: {
          media_object_id: MEDIA_OBJECT_ID,
          replaced_media_object_id: null,
        },
        error: null,
      }),
    failSession: (_admin, _sid, _code) => Promise.resolve({ error: null }),
    callCf: (_uuid) => Promise.resolve(okCfResult()),
    deleteFromR2: (_key) => Promise.resolve(),
    downloadFromR2: (_key) => Promise.resolve(makeWebPBytes()),
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Happy path
// ---------------------------------------------------------------------------

Deno.test(
  "Happy path → 200, status = pending_review, media_object_id present",
  async () => {
    const handler = makeHandler(makeDeps());
    const res = await handler(makeRequest());
    assertEquals(res.status, 200);
    const body = await res.json();
    assertEquals(body.status, "pending_review");
    assertEquals(body.media_object_id, MEDIA_OBJECT_ID);
  },
);

// ---------------------------------------------------------------------------
// CF Worker failure mapping
// ---------------------------------------------------------------------------

Deno.test("CF Worker 404 → fail_upload_session(FK_NOT_FOUND); 404", async () => {
  const failed: string[] = [];
  const handler = makeHandler(makeDeps({
    callCf: () => Promise.resolve(failCfResult("FK_NOT_FOUND")),
    failSession: (_admin, _sid, code) => {
      failed.push(code);
      return Promise.resolve({ error: null });
    },
  }));
  const res = await handler(makeRequest());
  assertEquals(res.status, 404);
  assertEquals(failed, ["FK_NOT_FOUND"]);
});

Deno.test(
  "CF Worker 422 → fail_upload_session(FK_PROCESSING_FAILED); 422",
  async () => {
    const failed: string[] = [];
    const handler = makeHandler(makeDeps({
      callCf: () => Promise.resolve(failCfResult("FK_PROCESSING_FAILED")),
      failSession: (_admin, _sid, code) => {
        failed.push(code);
        return Promise.resolve({ error: null });
      },
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 422);
    assertEquals(failed, ["FK_PROCESSING_FAILED"]);
  },
);

Deno.test(
  "CF Worker 5xx (FK_INTERNAL) → fail_upload_session(FK_INTERNAL); 500",
  async () => {
    const failed: string[] = [];
    const handler = makeHandler(makeDeps({
      callCf: () => Promise.resolve(failCfResult("FK_INTERNAL")),
      failSession: (_admin, _sid, code) => {
        failed.push(code);
        return Promise.resolve({ error: null });
      },
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 500);
    assertEquals(failed, ["FK_INTERNAL"]);
  },
);

Deno.test(
  "CF Worker fetch throws → fail_upload_session(FK_INTERNAL); 500",
  async () => {
    const failed: string[] = [];
    const handler = makeHandler(makeDeps({
      callCf: () =>
        Promise.resolve({
          ok: false as const,
          fkCode: "FK_INTERNAL" as const,
          workerStatus: 0,
        }),
      failSession: (_admin, _sid, code) => {
        failed.push(code);
        return Promise.resolve({ error: null });
      },
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 500);
    assertEquals(failed, ["FK_INTERNAL"]);
  },
);

// ---------------------------------------------------------------------------
// CF Worker 200 validation failures
// ---------------------------------------------------------------------------

Deno.test(
  "CF Worker 200 but displayKey ≠ session.display_storage_path → FK_INTERNAL; 500",
  async () => {
    const failed: string[] = [];
    const handler = makeHandler(makeDeps({
      callCf: () =>
        Promise.resolve({
          ok: true as const,
          displayKey: "wrong/key.webp",
          sha256: VALID_SHA256,
          bytes: 1024,
        }),
      failSession: (_admin, _sid, code) => {
        failed.push(code);
        return Promise.resolve({ error: null });
      },
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 500);
    assertEquals(failed, ["FK_INTERNAL"]);
  },
);

Deno.test(
  "CF Worker 200 but sha256 invalid format → FK_INTERNAL; 500",
  async () => {
    const failed: string[] = [];
    const handler = makeHandler(makeDeps({
      callCf: () =>
        Promise.resolve({
          ok: true as const,
          displayKey: DISP_PATH,
          sha256: "ZZZZ",
          bytes: 1024,
        }),
      failSession: (_admin, _sid, code) => {
        failed.push(code);
        return Promise.resolve({ error: null });
      },
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 500);
    assertEquals(failed, ["FK_INTERNAL"]);
  },
);

Deno.test(
  "CF Worker 200 but bytes out of range → FK_INTERNAL; 500",
  async () => {
    const failed: string[] = [];
    const handler = makeHandler(makeDeps({
      callCf: () =>
        Promise.resolve({
          ok: true as const,
          displayKey: DISP_PATH,
          sha256: VALID_SHA256,
          bytes: 0,
        }),
      failSession: (_admin, _sid, code) => {
        failed.push(code);
        return Promise.resolve({ error: null });
      },
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 500);
    assertEquals(failed, ["FK_INTERNAL"]);
  },
);

// ---------------------------------------------------------------------------
// Idempotency branch
// ---------------------------------------------------------------------------

Deno.test("Idempotent complete on entry → 200 already_complete: true", async () => {
  const handler = makeHandler(makeDeps({
    resolveSession: () =>
      Promise.resolve({
        data: makeSession({
          status: "complete",
          media_object_id: MEDIA_OBJECT_ID,
        }),
        error: null,
      }),
  }));
  const res = await handler(makeRequest());
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.already_complete, true);
  assertEquals(body.media_object_id, MEDIA_OBJECT_ID);
});

Deno.test("processing on entry → 202", async () => {
  const handler = makeHandler(makeDeps({
    resolveSession: () =>
      Promise.resolve({
        data: makeSession({ status: "processing" }),
        error: null,
      }),
  }));
  const res = await handler(makeRequest());
  assertEquals(res.status, 202);
  const body = await res.json();
  assertEquals(body.status, "processing");
});

// ---------------------------------------------------------------------------
// Sanitized re-entry
// ---------------------------------------------------------------------------

Deno.test(
  "Sanitized re-entry: valid WebP → original deleted (SR-1), SHA-256 computed, finalized → 200",
  async () => {
    const deleted: string[] = [];
    const handler = makeHandler(makeDeps({
      resolveSession: () =>
        Promise.resolve({
          data: makeSession({ status: "sanitized" }),
          error: null,
        }),
      deleteFromR2: (key) => {
        deleted.push(key);
        return Promise.resolve();
      },
      downloadFromR2: (_key) => Promise.resolve(makeWebPBytes()),
      finalizeSession: (_admin, _sid, _hash) =>
        Promise.resolve({
          data: {
            media_object_id: MEDIA_OBJECT_ID,
            replaced_media_object_id: null,
          },
          error: null,
        }),
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 200);
    assertEquals(deleted.includes(ORIG_PATH), true);
  },
);

Deno.test(
  "Sanitized re-entry: original absent → SR-1 no-op; continues to SR-2",
  async () => {
    // NoSuchKey from deleteFromR2 should be treated as success
    const handler = makeHandler(makeDeps({
      resolveSession: () =>
        Promise.resolve({
          data: makeSession({ status: "sanitized" }),
          error: null,
        }),
      deleteFromR2: (key) => {
        if (key === ORIG_PATH) {
          const err = new Error("NoSuchKey");
          err.name = "NoSuchKey";
          return Promise.reject(err);
        }
        return Promise.resolve();
      },
      downloadFromR2: (_key) => Promise.resolve(makeWebPBytes()),
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 200);
  },
);

Deno.test(
  "Sanitized re-entry: original deletion fails all retries → display deleted; session failed; 422",
  async () => {
    const failed: string[] = [];
    const handler = makeHandler(makeDeps({
      resolveSession: () =>
        Promise.resolve({
          data: makeSession({ status: "sanitized" }),
          error: null,
        }),
      deleteFromR2: (_key) => Promise.reject(new Error("R2 error")),
      failSession: (_admin, _sid, code) => {
        failed.push(code);
        return Promise.resolve({ error: null });
      },
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 422);
    assertEquals(failed, ["FK_PROCESSING_FAILED"]);
  },
);

Deno.test("Sanitized re-entry: display absent → 422", async () => {
  const failed: string[] = [];
  const handler = makeHandler(makeDeps({
    resolveSession: () =>
      Promise.resolve({
        data: makeSession({ status: "sanitized" }),
        error: null,
      }),
    deleteFromR2: (_key) => Promise.resolve(),
    downloadFromR2: (_key) => Promise.resolve(null),
    failSession: (_admin, _sid, code) => {
      failed.push(code);
      return Promise.resolve({ error: null });
    },
  }));
  const res = await handler(makeRequest());
  assertEquals(res.status, 422);
  assertEquals(failed, ["FK_PROCESSING_FAILED"]);
});

Deno.test(
  "Sanitized re-entry: display invalid WebP → display deleted; session failed; 422",
  async () => {
    const failed: string[] = [];
    const deleted: string[] = [];
    const handler = makeHandler(makeDeps({
      resolveSession: () =>
        Promise.resolve({
          data: makeSession({ status: "sanitized" }),
          error: null,
        }),
      deleteFromR2: (key) => {
        deleted.push(key);
        return Promise.resolve();
      },
      // not WebP
      downloadFromR2: (_key) =>
        Promise.resolve(new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])),
      failSession: (_admin, _sid, code) => {
        failed.push(code);
        return Promise.resolve({ error: null });
      },
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 422);
    assertEquals(failed, ["FK_PROCESSING_FAILED"]);
    assertEquals(deleted.includes(DISP_PATH), true);
  },
);

// ---------------------------------------------------------------------------
// Lease expiry
// ---------------------------------------------------------------------------

Deno.test(
  "Lease expiry (step 5) → original deleted; 422 FK_PROCESSING_FAILED; no fail_upload_session",
  async () => {
    const failed: string[] = [];
    const deleted: string[] = [];
    const handler = makeHandler(makeDeps({
      checkLease: (_admin, _sid) =>
        Promise.resolve({ data: false, error: null }),
      deleteFromR2: (key) => {
        deleted.push(key);
        return Promise.resolve();
      },
      failSession: (_admin, _sid, code) => {
        failed.push(code);
        return Promise.resolve({ error: null });
      },
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 422);
    // fail_upload_session must NOT be called for lease expiry
    assertEquals(failed.length, 0);
    assertEquals(deleted.includes(ORIG_PATH), true);
  },
);

// ---------------------------------------------------------------------------
// Original deletion failure (step 7)
// ---------------------------------------------------------------------------

Deno.test(
  "Original deletion failure (step 7, 2 retries) → display deleted; fail_session; 422",
  async () => {
    const failed: string[] = [];
    const deleted: string[] = [];
    const handler = makeHandler(makeDeps({
      deleteFromR2: (key) => {
        if (key === ORIG_PATH) return Promise.reject(new Error("R2 error"));
        deleted.push(key);
        return Promise.resolve();
      },
      failSession: (_admin, _sid, code) => {
        failed.push(code);
        return Promise.resolve({ error: null });
      },
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 422);
    assertEquals(failed, ["FK_PROCESSING_FAILED"]);
    assertEquals(deleted.includes(DISP_PATH), true);
  },
);

// ---------------------------------------------------------------------------
// Step 6 RPC error recovery
// ---------------------------------------------------------------------------

Deno.test(
  "Step 6 RPC error: re-resolve sanitized → sanitized re-entry path",
  async () => {
    let resolveCount = 0;
    const handler = makeHandler(makeDeps({
      resolveSession: () => {
        resolveCount++;
        if (resolveCount === 1) {
          return Promise.resolve({
            data: makeSession({ status: "pending" }),
            error: null,
          });
        }
        return Promise.resolve({
          data: makeSession({ status: "sanitized" }),
          error: null,
        });
      },
      advanceSanitized: () =>
        Promise.resolve({ error: new Error("RPC error") }),
      downloadFromR2: () => Promise.resolve(makeWebPBytes()),
      deleteFromR2: () => Promise.resolve(),
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 200);
  },
);

Deno.test(
  "Step 6 RPC error: re-resolve processing → display + original deleted; fail_session; 500",
  async () => {
    let resolveCount = 0;
    const failed: string[] = [];
    const deleted: string[] = [];
    const handler = makeHandler(makeDeps({
      resolveSession: () => {
        resolveCount++;
        if (resolveCount === 1) {
          return Promise.resolve({
            data: makeSession({ status: "pending" }),
            error: null,
          });
        }
        return Promise.resolve({
          data: makeSession({ status: "processing" }),
          error: null,
        });
      },
      advanceSanitized: () =>
        Promise.resolve({ error: new Error("RPC error") }),
      deleteFromR2: (key) => {
        deleted.push(key);
        return Promise.resolve();
      },
      failSession: (_admin, _sid, code) => {
        failed.push(code);
        return Promise.resolve({ error: null });
      },
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 500);
    assertEquals(failed, ["FK_INTERNAL"]);
    assertEquals(deleted.includes(ORIG_PATH), true);
    assertEquals(deleted.includes(DISP_PATH), true);
  },
);

Deno.test(
  "Step 6 RPC error: re-resolve complete → original deletion attempted; 200 idempotent",
  async () => {
    let resolveCount = 0;
    const deleted: string[] = [];
    const handler = makeHandler(makeDeps({
      resolveSession: () => {
        resolveCount++;
        if (resolveCount === 1) {
          return Promise.resolve({
            data: makeSession({ status: "pending" }),
            error: null,
          });
        }
        return Promise.resolve({
          data: makeSession({
            status: "complete",
            media_object_id: MEDIA_OBJECT_ID,
          }),
          error: null,
        });
      },
      advanceSanitized: () =>
        Promise.resolve({ error: new Error("RPC error") }),
      deleteFromR2: (key) => {
        deleted.push(key);
        return Promise.resolve();
      },
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 200);
    const body = await res.json();
    assertEquals(body.already_complete, true);
    assertEquals(deleted.includes(ORIG_PATH), true);
  },
);

// ---------------------------------------------------------------------------
// Finalization error recovery
// ---------------------------------------------------------------------------

Deno.test(
  "Finalization commits, response lost: re-resolve complete; 200 idempotent",
  async () => {
    let resolveCount = 0;
    const handler = makeHandler(makeDeps({
      resolveSession: () => {
        resolveCount++;
        if (resolveCount === 1) {
          return Promise.resolve({
            data: makeSession({ status: "pending" }),
            error: null,
          });
        }
        return Promise.resolve({
          data: makeSession({
            status: "complete",
            media_object_id: MEDIA_OBJECT_ID,
          }),
          error: null,
        });
      },
      finalizeSession: () =>
        Promise.resolve({ data: null, error: new Error("transport error") }),
      deleteFromR2: () => Promise.resolve(),
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 200);
    const body = await res.json();
    assertEquals(body.already_complete, true);
  },
);

Deno.test(
  "FK_INVALID_HASH → re-resolve sanitized → 422 FK_PROCESSING_FAILED",
  async () => {
    let resolveCount = 0;
    const handler = makeHandler(makeDeps({
      resolveSession: () => {
        resolveCount++;
        if (resolveCount === 1) {
          return Promise.resolve({
            data: makeSession({ status: "pending" }),
            error: null,
          });
        }
        return Promise.resolve({
          data: makeSession({ status: "sanitized" }),
          error: null,
        });
      },
      finalizeSession: () => {
        const err = new Error("FK_INVALID_HASH: bad hash");
        return Promise.resolve({ data: null, error: err });
      },
      deleteFromR2: () => Promise.resolve(),
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 422);
    const body = await res.json();
    assertStringIncludes(body.error.code, "FK_PROCESSING_FAILED");
  },
);

Deno.test(
  "FK_WRONG_STATE → re-resolve sanitized → 409 FK_WRONG_STATE",
  async () => {
    let resolveCount = 0;
    const handler = makeHandler(makeDeps({
      resolveSession: () => {
        resolveCount++;
        if (resolveCount === 1) {
          return Promise.resolve({
            data: makeSession({ status: "pending" }),
            error: null,
          });
        }
        return Promise.resolve({
          data: makeSession({ status: "sanitized" }),
          error: null,
        });
      },
      finalizeSession: () => {
        const err = new Error("FK_WRONG_STATE: wrong state");
        return Promise.resolve({ data: null, error: err });
      },
      deleteFromR2: () => Promise.resolve(),
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 409);
    const body = await res.json();
    assertStringIncludes(body.error.code, "FK_WRONG_STATE");
  },
);

Deno.test(
  "Transport error from finalization → re-resolve sanitized → 500 FK_INTERNAL",
  async () => {
    let resolveCount = 0;
    const handler = makeHandler(makeDeps({
      resolveSession: () => {
        resolveCount++;
        if (resolveCount === 1) {
          return Promise.resolve({
            data: makeSession({ status: "pending" }),
            error: null,
          });
        }
        return Promise.resolve({
          data: makeSession({ status: "sanitized" }),
          error: null,
        });
      },
      finalizeSession: () =>
        Promise.resolve({ data: null, error: new Error("transport error") }),
      deleteFromR2: () => Promise.resolve(),
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 500);
    const body = await res.json();
    assertStringIncludes(body.error.code, "FK_INTERNAL");
  },
);

// ---------------------------------------------------------------------------
// Token / auth failures
// ---------------------------------------------------------------------------

Deno.test("Invalid / expired / failed token → 400 FK_INVALID_TOKEN", async () => {
  const handler = makeHandler(makeDeps({
    resolveSession: () => Promise.resolve({ data: null, error: null }),
  }));
  const res = await handler(makeRequest());
  assertEquals(res.status, 400);
  const body = await res.json();
  assertEquals(body.error.code, "FK_INVALID_TOKEN");
});

Deno.test("Unauthenticated → 401", async () => {
  const handler = makeHandler(makeDeps({
    getAuth: () => Promise.resolve(makeUnauthResult()),
  }));
  const res = await handler(makeRequest());
  assertEquals(res.status, 401);
});

Deno.test(
  "Missing CF env vars → 500 FK_INTERNAL (no credential leak)",
  async () => {
    // Simulate CF returning FK_INTERNAL due to missing env
    const handler = makeHandler(makeDeps({
      callCf: () =>
        Promise.resolve({
          ok: false as const,
          fkCode: "FK_INTERNAL" as const,
          workerStatus: 0,
        }),
      failSession: () => Promise.resolve({ error: null }),
    }));
    const res = await handler(makeRequest());
    assertEquals(res.status, 500);
    const body = await res.json();
    // Verify credentials are not leaked
    const bodyText = JSON.stringify(body);
    assertEquals(bodyText.includes("CLIENT_ID"), false);
    assertEquals(bodyText.includes("CLIENT_SECRET"), false);
  },
);

// ---------------------------------------------------------------------------
// Method enforcement
// ---------------------------------------------------------------------------

Deno.test("GET request → 405", async () => {
  const handler = makeHandler(makeDeps());
  const res = await handler(
    new Request("https://example.com/upload-complete", { method: "GET" }),
  );
  assertEquals(res.status, 405);
});
