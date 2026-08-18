# Gate 2A — magick-wasm Spike Results

**Date:** 2026-08-13T12:07:03.935Z
**Verdict:** ⚠️ GATE 2A PARTIALLY PASSED — additional evidence required (see Section 8)

---

## 1. WASM Binary

| Property | Value |
|---|---|
| Package | `@imagemagick/magick-wasm@0.0.42` |
| Binary | `dist/magick.wasm` |
| Size | **14.0 MB** (14,687,945 bytes) |
| Load approach | `Deno.readFile(path)` → `initializeImageMagick(bytes)` |
| static_files viable | Yes — file loads cleanly from local path; Edge Function uses same pattern |

---

## 2. Canonical Pre-Decode Pixel Limit

### **20,000,000 pixels (20 MP)**

| Item | Value |
|---|---|
| Edge Function memory limit | 256 MB |
| magick-wasm runtime overhead | ~70 MB |
| Available for raw raster | ~186 MB |
| At 4 bytes/pixel (RGBA) | ~46 MP theoretical ceiling |
| Safety factor | 2× |
| **Canonical limit** | **20 MP** |

The limit is enforced by parsing the image file header **before** any bytes reach the WASM decoder.
Images exceeding the limit are rejected immediately with HTTP 422 — the WASM module is never invoked.

---

## 3. Pre-Decode Header Parser

| Case | Result |
|---|---|
| 100×100 (10K px — tiny) | 100×100 = 10,000 px → ACCEPTED |
| 4000×3000 (12M px — iPhone std) | 4000×3000 = 12,000,000 px → ACCEPTED |
| 5000×4000 (20M px — at limit) | 5000×4000 = 20,000,000 px → ACCEPTED |
| 5001×4000 (20.004M px — over) | 5001×4000 = 20,004,000 px → REJECTED pre-decode |
| 10000×10000 (100M px — bomb) | 10000×10000 = 100,000,000 px → REJECTED pre-decode |

---

## 4. Decode + WebP Re-encode Matrix

| Case | Result |
|---|---|
| 
### Part 4 | Decode + WebP re-encode matrix |
| 100×100 (0.01 MP) | 12 ms → WebP 0 KB |
| 1000×750 (0.75 MP) | 52 ms → WebP 1 KB |
| 2000×1500 (3.00 MP) | 152 ms → WebP 5 KB |

---

## 5. static_files Packaging

The Edge Function WASM load pattern:

```typescript
// In upload-complete/index.ts (simulated by this spike)
const wasmBytes = await Deno.readFile(
  new URL("../_shared/magick.wasm", import.meta.url)
);
await initializeImageMagick(wasmBytes);
```

Required `config.toml` entry:

```toml
[functions.upload-complete]
static_files = ["supabase/functions/_shared/magick.wasm"]
```

**CLI version requirement:** ≥ 2.7.0 (for `static_files` support).
Bill: run `supabase --version` and record below.

---

## 6. Supabase CLI Version

```
2.111.0
```

Required: ≥ 2.7.0 — **✅ CONFIRMED** (2.111.0 far exceeds requirement)

---

## 7. Next Steps

- [x] Confirm `supabase --version` ≥ 2.7.0 (2.111.0 confirmed)
- [ ] Complete Gate 2A remaining evidence (see Section 8)
- [ ] Three-party approval of canonical pixel limit (20 MP) — pending complete evidence
- [ ] Gate 2B: hosted spike on forkensics-dev (requires separate three-party approval; blocked on Gate 2A)
- [ ] Add `CREATE EXTENSION IF NOT EXISTS pg_cron;` to migrations (three-party-approved migration required before any cron Edge Function TypeScript)
- [ ] Step A (upload-authorize): drafting may proceed — independent of image processing

---

## 8. Gate 2A — Remaining Evidence Required (GPT verdict 2026-08-13)

Gate 2A is **partially passed**. The following items must be completed before Gate 2A is fully closed:

1. **Full file-size matrix** — 5 MB JPEG, 10 MB JPEG, 5 MB WebP: decode, re-encode, measure timing
2. **Pre-decode header parsing for JPEG and WebP** — not only PNG; parsers must be tested with real file headers
3. **Actual decode tests at and around 20 MP boundary** — images at 19 MP, 20 MP, and 21 MP (rejected pre-decode)
4. **Measured peak memory at the 20 MP boundary** — theoretical estimate alone is insufficient; use process memory introspection or RSS delta
5. **Structural proof of metadata removal** — EXIF, GPS, ICC, XMP, IPTC, and comments stripped; verified programmatically on the re-encoded output
6. **Full bundled function size** — total size of the Edge Function bundle including WASM, not only the 14 MB binary alone
7. **`supabase functions serve` compatibility test** — static_files load must be verified through Supabase's Edge Runtime, not only standalone Deno 2.9.5
