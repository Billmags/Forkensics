# Gate 2B Proposal — Rev 14 — Pixel Ceiling Discovery Spike on forkensics-dev

**Status:** DRAFT — awaiting three-party approval

**Governance gate:** Three-party approval (Bill + Claude + Codex) required before any cloud operation is executed. The magic words are `APPROVED: Gate 2B Rev 14 — Pixel Ceiling Discovery Spike`.

**Authorized by:** Step 27 Rev 5 §3 Gate 2 Phase B.

**Supersedes:** Gate 2B Rev 13 (DRAFT — 2 telemetry blockers + 2 consistency fixes identified by Codex; never approved).

**Rev 14 changes from Rev 13 (all 4 findings addressed + S-15 q_start corrected):**

**S-15 q_start corrected:** `q_start=72` produced ~8.59 MB for the 5000×3000 fixture, below the required 9–10 MB band. Because the loop only decreases quality, it could never recover. Corrected to `q_start=79`, which produces ~9.80 MB (verified: 9,802,741 bytes, all 6 metadata families pass).

1. **Blocker 1 — Subshell no longer swallows `fail()` calls.** `survey_telemetry_result()` was called via `$(…)` command substitution, which runs in a subshell. Any `fail()` call inside modified `GATE2B_PASS` and `FAIL_REASONS` only in the subshell; the parent runner was unaffected and could reach PASS despite an evidence-quality failure. Fixed by:
   - Removing `echo "pass"/"nonviable"/"evidence_fail"` from the function
   - Replacing with a global `SURVEY_TELEM_OUTCOME=""` variable set directly inside the function
   - Calling the function without `$(…)`: `survey_telemetry_result "$sid"` — runs in the parent shell so `fail()` propagates normally
   - Checking `$SURVEY_TELEM_OUTCOME` after the call in the parent; an `evidence_fail` immediately exits the runner

2. **Blocker 2 — All telemetry fields validated before classification.** Previously, if `shutdown_reason` was a resource-limit value (e.g. `Memory`), the function returned `nonviable` before checking whether CPU and memory values were numeric, finite, and nonnegative — so `cpu=abc, mem="", reason=Memory` was silently accepted as ordinary nonviability instead of an evidence-quality failure. The validation order is now strictly:
   1. INCONCLUSIVE check → evidence_fail
   2. UUID format validation → evidence_fail
   3. CPU numeric/finite/nonneg validation → evidence_fail
   4. Memory numeric/finite/nonneg validation → evidence_fail
   5. Reason in recognized set (OK ∪ RESOURCE) → evidence_fail if unrecognized
   6. Only after all fields pass: classify as `pass` or `nonviable`

3. **Consistency fix — C-REJECT 546 now exits immediately.** The proposal stated "calls `fail()` and exits" but the runner only called `fail()`. Added `exit 1` after the `fail()` call for C-REJECT 546 to match the stated hard-stop behavior.

4. **Consistency fix — RIFF validation requires exact size.** Previously the check was `file_size + 8 > len(data)`, which rejected containers claiming more data than is present but silently accepted trailing bytes outside the declared container. Changed to `file_size + 8 != len(data)` in both `gate2b-fixtures-r14.py` and `gate2b-verify-input-metadata.py`.

---

## Section 1 — Prerequisites

### 1.1 Rev 9 Evidence Required

`tools/image-spike/gate2b-evidence-20260814T194105Z/gate2b-results.md` must be present with SHA-256 `3903f9dc08bb7edc77720911a614a9656ad97b5c9e42a04c9a50d60f3fd1bc4f`.

### 1.2 Pre-Deployment Code Review (blocks deployment)

Before the runner invokes `supabase functions deploy` for any phase, all three parties must sign off on:

- `supabase/functions/image-spike/index.ts` — survey version (`CANONICAL_PIXEL_LIMIT = 15_500_000`; `uint8ArrayToBase64`; `imageDecodeStarted` field)
- `supabase/config.toml` diff (`[functions.image-spike]` section only)
- `tools/image-spike/gate2b-run-r14.sh`
- `tools/image-spike/gate2b-fixtures-r14.py`
- `tools/image-spike/gate2b-verify-metadata.py`
- `tools/image-spike/gate2b-verify-input-metadata.py`
- SHA-256 of `magick.wasm` and `index.ts` (survey version)
- Local Edge Runtime result (§1.3)
- `deno fmt --check`, `deno lint`, `deno check` — zero findings
- `bash -n tools/image-spike/gate2b-run-r14.sh` — exit 0
- `python3 -m py_compile` for all three Python scripts — exit 0
- `gitleaks detect` — no findings

### 1.3 Local Edge Runtime Verification

Run `bash tools/image-spike/gate2b-local-test-r14.sh` before Phase S-1. S-5 (`image_decode_started: true`) and a rejection fixture (`image_decode_started: false`) must pass.

---

## Section 2 — Purpose

Gate 2B Rev 9 proved 20 MP exceeds Supabase's 256 MiB memory ceiling (293.5 MiB peak). Rev 14 finds the highest pixel count satisfying both:

- `memory_used.total` (ShutdownEvent) ≤ 200 MiB
- `cpu_time_used` (ShutdownEvent) ≤ 1,500 ms

The established ceiling becomes `CANONICAL_PIXEL_LIMIT` enforced server-side and the mandatory upload limit enforced iOS client-side before any upload attempt.

---

## Section 3 — Authorized Cloud Operations

**Project:** `hkfrbdpedrxmbsawnbpr` (forkensics-dev). No other project ref is authorized.

Up to 9 sequential deployments of `image-spike`:

| Phase | Deploy | Invocations | Purpose |
|---|---|---|---|
| S-1 | 1 | S-5 (5 MP JPEG) | Survey cold start |
| S-2 | 1 | S-8 (8 MP JPEG) | Survey cold start |
| S-3 | 1 | S-10 (10 MP JPEG) | Survey cold start |
| S-4 | 1 | S-12 (12 MP JPEG) | Survey cold start |
| S-5 | 1 | S-15 (15 MP JPEG) | Survey cold start |
| C-1 | 1 | C-JPEG-1 (seed=42, cold) | Confirmation run 1 |
| C-2 | 1 | C-JPEG-2 (seed=43, cold) | Confirmation run 2 |
| C-3 | 1 | C-JPEG-3 (seed=44, cold) | Confirmation run 3 |
| C-4 | 1 | C-WEBP (cold) → C-REJECT (warm) | Format + rejection |

A 546 at survey level N stops ascent without failing the gate; ceiling selection proceeds with levels below N. A 546 with no viable lower level is a hard Gate FAIL. Confirmation phase 546s are hard Gate FAILs and exit immediately.

---

## Section 4 — Spike Function Design

### 4.1 Location

`supabase/functions/image-spike/index.ts` — first line: `// DISPOSABLE — Gate 2B only. Delete after results recorded. Do not merge to main.`

### 4.2 Handler Pipeline (unchanged from Rev 13)

```typescript
const CANONICAL_PIXEL_LIMIT = 15_500_000; // survey; overwritten for confirmation

function uint8ArrayToBase64(data: Uint8Array): string {
  let binary = "";
  const CHUNK = 8192;
  for (let i = 0; i < data.length; i += CHUNK) {
    binary += String.fromCharCode(
      ...data.subarray(i, Math.min(i + CHUNK, data.length)),
    );
  }
  return btoa(binary);
}

Deno.serve(async (req: Request): Promise<Response> => {
  const run_id = crypto.randomUUID();
  const url = new URL(req.url);
  const label = url.searchParams.get("label") ?? "unlabeled";
  console.log(JSON.stringify({ event: "invoke", run_id, label }));

  const mem_before_rss = Deno.memoryUsage().rss;
  const t0 = performance.now();

  const body = new Uint8Array(await req.arrayBuffer());
  const input_size_bytes = body.byteLength;

  const { width, height } = parseImageHeader(body);
  const pixel_count = width * height;

  let imageDecodeStarted = false;

  if (pixel_count > CANONICAL_PIXEL_LIMIT) {
    return Response.json({
      run_id, label,
      accepted: false,
      reason: "pre_decode_rejected",
      pixel_count, width, height,
      image_decode_started: imageDecodeStarted,
    });
  }

  imageDecodeStarted = true;

  const result = await ImageMagick.read(body, async (img) => {
    img.strip();
    return new Promise<Uint8Array>((resolve) => {
      img.write(MagickFormat.WebP, (data) => resolve(data));
    });
  });

  const mem_after_rss = Deno.memoryUsage().rss;
  const wall_time_ms = performance.now() - t0;

  const outputValid =
    result[0] === 0x52 && result[1] === 0x49 &&
    result[2] === 0x46 && result[3] === 0x46 &&
    result[8] === 0x57 && result[9] === 0x45 &&
    result[10] === 0x42 && result[11] === 0x50;

  const sha256hex = await sha256(result);
  const output_bytes = uint8ArrayToBase64(result);

  return Response.json({
    run_id, label,
    accepted: true,
    image_decode_started: imageDecodeStarted,
    pixel_count, width, height,
    input_size_bytes,
    output_size_bytes: result.byteLength,
    metadata_clean: outputValid,
    sha256: sha256hex,
    output_bytes,
    diagnostic: {
      mem_before_rss_bytes: mem_before_rss,
      mem_after_rss_bytes: mem_after_rss,
      wall_time_ms,
    },
  });
});
```

### 4.3 CANONICAL_PIXEL_LIMIT Values

| Version | Value | Phases |
|---|---|---|
| Survey | `15_500_000` | S-1 through S-5 |
| Confirmation | `<CHOSEN_CEILING_PX>` | C-1 through C-4 |

### 4.4 config.toml Entry

```toml
[functions.image-spike]
static_files = ["./functions/_shared/magick.wasm"]
```

---

## Section 5 — Test Manifest

### 5.1 Survey Fixtures (JPEG; all 6 metadata families)

| ID | W | H | Pixels | Min B | Max B |
|---|---|---|---|---|---|
| S-5 | 2500 | 2000 | 5,000,000 | 4,000,000 | 5,500,000 |
| S-8 | 4000 | 2000 | 8,000,000 | 6,500,000 | 9,000,000 |
| S-10 | 4000 | 2500 | 10,000,000 | 8,500,000 | 10,000,000 |
| S-12 | 4000 | 3000 | 12,000,000 | 9,000,000 | 10,000,000 |
| S-15 | 5000 | 3000 | 15,000,000 | 9,000,000 | 10,000,000 |

All fixtures: COMMENT, EXIF, GPS, ICC, IPTC, XMP.

### 5.2 Confirmation Fixtures

| ID | Format | Seed | Pixels | Min B | Max B | accepted |
|---|---|---|---|---|---|---|
| C-JPEG-1 | JPEG | 42 | ceiling_px | survey_min | survey_max | true |
| C-JPEG-2 | JPEG | 43 | ceiling_px | survey_min | survey_max | true |
| C-JPEG-3 | JPEG | 44 | ceiling_px | survey_min | survey_max | true |
| C-WEBP | WebP | 42 | ceiling_px | — | 10,000,000 | true |
| C-REJECT | JPEG | — | (cw+1)×ch | — | 500,000 | false |

---

## Section 6 — Pass Criteria

### 6.1 Survey Phase Pass Criteria

| # | Criterion | Threshold |
|---|---|---|
| S1 | curl exit code | 0 |
| S2 | HTTP status | 200 (546 → boundary; see §7) |
| S3 | `accepted` | true |
| S4 | `label` | matches fixture ID |
| S5 | `run_id` | valid UUID |
| S6 | `width`, `height`, `pixel_count` | match manifest |
| S7 | `input_size_bytes` | equals `wc -c` of fixture |
| S8 | `metadata_clean` | true |
| S9 | `image_decode_started` | true |
| S10 | `output_bytes` decodes to valid WebP | RIFF/WEBP header |
| S11 | SHA-256 recomputed from `output_bytes` | matches `sha256` |
| S12 | `output_size_bytes` | equals decoded byte count |
| S13 | RIFF chunk parser (output) | EXIF, ICCP, XMP absent |
| S14 | Cold-start wall time | ≤ 30 s |
| S15 | Bundle size | ≤ 20 MB |
| S16 | `cpu_time_used` (ShutdownEvent) — validated, then threshold | ≤ 1,500 ms (nonviable if exceeded; evidence_fail if malformed) |
| S17 | `memory_used.total` (ShutdownEvent ÷ 1,048,576) | ≤ 200 MiB (nonviable if exceeded; evidence_fail if malformed) |
| S18 | `shutdown_reason` (ShutdownEvent) | in OK set; nonviable if resource-limit; evidence_fail if unknown |

### 6.2 Ceiling Selection Criterion

A survey level is **viable** if: S1–S15 all passed (functional) AND `SURVEY_TELEM_OUTCOME == "pass"`.

### 6.3 Confirmation Phase Pass Criteria

| # | Criterion | Threshold |
|---|---|---|
| C1–C4 | S1–S15 same thresholds | — |
| C5 | `cpu_time_used` | ≤ 1,500 ms (hard Gate FAIL) |
| C6 | `memory_used.total` | ≤ 200 MiB (hard Gate FAIL) |
| C7 | `shutdown_reason` | in OK set (hard Gate FAIL) |
| C8 | C-JPEG-1,2,3 byte size | within survey band for chosen MP |
| C9 | C-WEBP cold wall time | ≤ 30 s |
| C10 | C-REJECT: HTTP | 200; 546 → immediate exit |
| C11 | C-REJECT: `accepted` | false |
| C12 | C-REJECT: `reason` | `pre_decode_rejected` |
| C13 | C-REJECT: `image_decode_started` | false |
| C14 | C-REJECT: `pixel_count` | `(ceiling_w + 1) × ceiling_h` |

---

## Section 7 — Failure and Inconclusive Definitions

**Hard failures (runner exits immediately):**
- HTTP 401 or 403 in any phase
- HTTP 546 at survey 5 MP with no viable lower level
- HTTP 546 in any confirmation phase (C-1 through C-4, including C-REJECT) — exits immediately after `fail()`
- Bundle > 20 MB or unparseable
- JWT preflight failure; deletion unconfirmed; ceiling selection returns NONE
- Operator ceiling entry invalid or > RECOMMENDED_CEILING
- Confirmation fixture preflight fails
- Survey telemetry `evidence_fail` (malformed, inconclusive, or unrecognized reason)

**Survey telemetry `nonviable` (no gate poison):** CPU > 1,500 ms, MiB > 200, or reason is a resource-limit value — but only after all fields pass validation. Level recorded as nonviable; `GATE2B_PASS` unchanged.

**Soft failures:** Any non-546 non-auth HTTP error; any S1–S14 assertion miss; wall-time exceeded.

---

## Section 8 — Telemetry Methodology

### 8.1 Two-Step Log Lookup

**Step 1:** Dashboard → edge-logs → filter `metadata.function_id = 'image-spike'` → search `run_id` → record `execution_id`.

**Step 2:** Search `execution_id` → find ShutdownEvent → extract `cpu_time_used`, `memory_used.total` (bytes, `total` sub-field), `reason`. Do NOT use WorkerMemoryUsed or Metrics UI.

### 8.2 Valid Shutdown Reasons

| `reason` | Category | Survey effect | Confirmation effect |
|---|---|---|---|
| `EventLoopCompleted` | OK | viable candidate | acceptable |
| `EarlyDrop` | OK | viable candidate | acceptable |
| `TerminationRequested` | OK | viable candidate | acceptable |
| `Memory` | Resource limit | nonviable (only after numeric validation passes) | hard Gate FAIL |
| `CPUTime` | Resource limit | nonviable (only after numeric validation passes) | hard Gate FAIL |
| `WallClockTime` | Resource limit | nonviable (only after numeric validation passes) | hard Gate FAIL |
| Any other | Unknown | evidence_fail → hard stop | evidence_fail → hard Gate FAIL |

---

## Section 9 — Ceiling Selection Algorithm

```python
MP = [5, 8, 10, 12, 15]
OK_REASONS = {"EventLoopCompleted", "EarlyDrop", "TerminationRequested"}
MIB = 1_048_576

# Per level: func_pass, telem_ok, cpu, mem, reason
# telem_ok="true" only if survey_telemetry_result set SURVEY_TELEM_OUTCOME="pass"
# (evidence_fail levels will have telem_ok="false" and will have already stopped the run)

viable = []
for mp in MP:
    fp    = survey_func_pass[mp]   # "true"/"false"
    tok   = survey_telem_ok[mp]    # "true"/"false"
    if fp != "true" or tok != "true":
        continue
    try:
        cpu = float(survey_cpu[mp])
        mem = float(survey_mem[mp])
    except (ValueError, TypeError):
        continue   # evidence_fail would have stopped the run already
    if survey_reason[mp] not in OK_REASONS:
        continue   # same — already stopped
    if cpu <= 1500 and mem / MIB <= 200:
        viable.append(mp)

recommended = max(viable) if viable else None
```

---

## Section 10 — Supporting Scripts

### 10.1 gate2b-verify-metadata.py

Unchanged from Rev 9.

### 10.2 gate2b-fixtures-r14.py

Changes from Rev 13: RIFF parser uses `!=` (exact size) instead of `>` for the container boundary check.

```python
#!/usr/bin/env python3
"""gate2b-fixtures-r14.py — Rev 14 fixture generator.
Usage:
  python3 gate2b-fixtures-r14.py <out_dir>
  python3 gate2b-fixtures-r14.py <out_dir> confirm <cw> <ch> <cp> <min_b> <max_b>
Requires: Pillow >= 9.3.0, piexif, numpy
"""
import sys, os, io, struct, hashlib
import numpy as np
from PIL import Image, ImageCms
import piexif

SURVEY = [
    ("S-5",  2500, 2000,  5_000_000,  4_000_000,  5_500_000, 91),
    ("S-8",  4000, 2000,  8_000_000,  6_500_000,  9_000_000, 90),
    ("S-10", 4000, 2500, 10_000_000,  8_500_000, 10_000_000, 92),
    ("S-12", 4000, 3000, 12_000_000,  9_000_000, 10_000_000, 85),
    ("S-15", 5000, 3000, 15_000_000,  9_000_000, 10_000_000, 79),
]
UPLOAD_CEIL   = 10_000_000
REJECT_MAX_BYTES = 500_000

# ---------------------------------------------------------------------------
# Metadata builders
# ---------------------------------------------------------------------------
def _icc_profile() -> bytes:
    return ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()

def _exif_bytes() -> bytes:
    exif = {
        "0th": {
            piexif.ImageIFD.Make:     b"ForkensicsTest",
            piexif.ImageIFD.Model:    b"Rev14",
            piexif.ImageIFD.Software: b"gate2b-fixtures-r14",
        },
        "Exif": {
            piexif.ExifIFD.ExposureTime: (1, 100),
            piexif.ExifIFD.FNumber:      (28, 10),
        },
        "GPS": {
            piexif.GPSIFD.GPSLatitudeRef:  b"N",
            piexif.GPSIFD.GPSLatitude:     ((37,1),(46,1),(30,1)),
            piexif.GPSIFD.GPSLongitudeRef: b"W",
            piexif.GPSIFD.GPSLongitude:    ((122,1),(25,1),(0,1)),
        },
        "1st": {}, "thumbnail": None,
    }
    return piexif.dump(exif)

def _xmp_bytes() -> bytes:
    return (b'<?xpacket begin="\xef\xbb\xbf" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
            b'<x:xmpmeta xmlns:x="adobe:ns:meta/">'
            b'<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"/>'
            b'</x:xmpmeta>'
            b'<?xpacket end="w"?>')

def _iptc_app13() -> bytes:
    caption = b"Gate2B-Rev14-IPTC-Test"
    byline  = b"ForkensicsSpike"
    ds120 = b"\x1c\x02\x78" + struct.pack(">H", len(caption)) + caption
    ds080 = b"\x1c\x02\x50" + struct.pack(">H", len(byline)) + byline
    iptc_data = ds120 + ds080
    ps_hdr    = b"Photoshop 3.0\x00"
    bim_hdr   = b"8BIM\x04\x04\x00\x00"
    bim_block = bim_hdr + struct.pack(">I", len(iptc_data)) + iptc_data
    if len(bim_block) % 2:
        bim_block += b"\x00"
    payload = ps_hdr + bim_block
    return b"\xff\xed" + struct.pack(">H", 2 + len(payload)) + payload

_XMP_NS = b"http://ns.adobe.com/xap/1.0/\x00"

def _inject_app1_xmp(jpeg: bytes) -> bytes:
    xmp = _xmp_bytes()
    hdr = b"\xff\xe1" + struct.pack(">H", 2 + len(_XMP_NS) + len(xmp)) + _XMP_NS + xmp
    return jpeg[:2] + hdr + jpeg[2:]

def _inject_comment(jpeg: bytes, text: bytes = b"Gate2B-Rev14-COMMENT") -> bytes:
    hdr = b"\xff\xfe" + struct.pack(">H", 2 + len(text)) + text
    return jpeg[:2] + hdr + jpeg[2:]

# ---------------------------------------------------------------------------
# RIFF chunk parser — exact size required (no trailing bytes accepted)
# ---------------------------------------------------------------------------
def _parse_riff_chunks(data: bytes) -> dict:
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        raise ValueError("Not a RIFF/WEBP container")
    file_size = struct.unpack("<I", data[4:8])[0]
    if file_size + 8 != len(data):
        raise ValueError(
            f"RIFF declared size {file_size} implies total {file_size+8}B "
            f"but actual length is {len(data)}B")
    pos = 12
    out: dict = {}
    while pos + 8 <= len(data):
        tag  = data[pos:pos+4]
        size = struct.unpack("<I", data[pos+4:pos+8])[0]
        if pos + 8 + size > len(data):
            raise ValueError(
                f"Chunk {tag!r} at offset {pos} claims {size}B but only "
                f"{len(data)-pos-8} remain")
        out.setdefault(tag, []).append(data[pos+8:pos+8+size])
        pos += 8 + size + (size & 1)
    return out

# ---------------------------------------------------------------------------
# Image builders
# ---------------------------------------------------------------------------
def _noise_image(w: int, h: int, seed: int = 42) -> Image.Image:
    rng = np.random.default_rng(seed=seed)
    return Image.fromarray(rng.integers(0, 256, (h, w, 3), dtype=np.uint8), "RGB")

def _write_jpeg_full(img: Image.Image, quality: int, path: str) -> int:
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality, exif=_exif_bytes(), icc_profile=_icc_profile())
    raw = buf.getvalue()
    raw = _inject_app1_xmp(raw)
    raw = _inject_comment(raw)
    raw = raw[:2] + _iptc_app13() + raw[2:]
    with open(path, "wb") as f:
        f.write(raw)
    return len(raw)

def _write_webp_full(img: Image.Image, quality: int, path: str) -> int:
    buf = io.BytesIO()
    img.save(buf, "WEBP", quality=quality,
             exif=_exif_bytes(), icc_profile=_icc_profile(), xmp=_xmp_bytes())
    raw = buf.getvalue()
    chunks = _parse_riff_chunks(raw)
    missing = [t.decode() for t in (b"EXIF", b"ICCP", b"XMP ") if t not in chunks]
    if missing:
        raise RuntimeError(f"WebP missing chunks after save: {missing}. "
                           "Requires Pillow >= 9.3.0 with WebP xmp support.")
    with open(path, "wb") as f:
        f.write(raw)
    return len(raw)

# ---------------------------------------------------------------------------
# Survey fixture generation
# ---------------------------------------------------------------------------
def generate_survey(out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    print("Gate 2B Rev 14 survey fixture generation ...")
    for sid, w, h, px, lo, hi, q_start in SURVEY:
        path = os.path.join(out_dir, f"test-{sid}.jpg")
        img  = _noise_image(w, h, seed=42)
        size = -1
        for q in range(q_start, 49, -1):
            size = _write_jpeg_full(img, q, path)
            if lo <= size <= hi and size <= UPLOAD_CEIL:
                break
        if size < 0 or not (lo <= size <= hi) or size > UPLOAD_CEIL:
            print(f"FATAL: {sid} cannot meet band [{lo},{hi}] ≤ {UPLOAD_CEIL}",
                  file=sys.stderr)
            sys.exit(1)
        sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
        print(f"{sid} ({w}x{h}) q={q} size={size:,}B sha={sha[:16]}... ✓")
    print("=== Survey fixtures generated ===")

# ---------------------------------------------------------------------------
# Confirmation fixture generation
# ---------------------------------------------------------------------------
def generate_confirmation(out_dir: str, cw: int, ch: int, cp: int,
                          min_b: int, max_b: int) -> None:
    os.makedirs(out_dir, exist_ok=True)

    # C-JPEG-1, C-JPEG-2, C-JPEG-3 — finite sweep, no oscillation
    for i, seed in enumerate([42, 43, 44], start=1):
        path = os.path.join(out_dir, f"test-C-jpeg-{i}.jpg")
        img  = _noise_image(cw, ch, seed=seed)
        candidates = []
        for q in range(95, 49, -1):
            size = _write_jpeg_full(img, q, path)
            if min_b <= size <= max_b and size <= UPLOAD_CEIL:
                candidates.append((q, size))
        if not candidates:
            print(f"FATAL: C-JPEG-{i} (seed={seed}) cannot meet band "
                  f"[{min_b},{max_b}] at any quality in 50..95", file=sys.stderr)
            sys.exit(1)
        best_q, best_size = candidates[0]
        _write_jpeg_full(img, best_q, path)
        sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
        print(f"C-JPEG-{i} (seed={seed}): q={best_q} {cw}x{ch} "
              f"{best_size:,}B sha={sha[:16]}... ✓")

    # C-WEBP
    webp_path = os.path.join(out_dir, "test-C-webp.webp")
    img42 = _noise_image(cw, ch, seed=42)
    size_w = -1
    for q in range(90, 39, -5):
        size_w = _write_webp_full(img42, q, webp_path)
        if size_w <= UPLOAD_CEIL:
            break
    if size_w < 0 or size_w > UPLOAD_CEIL:
        print(f"FATAL: C-WEBP cannot get below {UPLOAD_CEIL}", file=sys.stderr)
        sys.exit(1)
    sha_w = hashlib.sha256(open(webp_path, "rb").read()).hexdigest()
    print(f"C-WEBP (seed=42): {cw}x{ch} {size_w:,}B sha={sha_w[:16]}... ✓")

    # C-REJECT — solid color, quality=1; must be ≤ 500,000 bytes
    reject_path = os.path.join(out_dir, "test-C-reject.jpg")
    Image.new("RGB", (cw+1, ch), (30, 60, 90)).save(reject_path, "JPEG", quality=1)
    size_r = os.path.getsize(reject_path)
    if size_r > REJECT_MAX_BYTES:
        print(f"FATAL: C-REJECT {size_r}B > {REJECT_MAX_BYTES}B ceiling",
              file=sys.stderr)
        sys.exit(1)
    print(f"C-REJECT: {cw+1}x{ch}={(cw+1)*ch:,}px {size_r:,}B ≤{REJECT_MAX_BYTES} ✓")
    print("=== Confirmation fixtures generated ===")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    out = sys.argv[1]
    if len(sys.argv) == 8 and sys.argv[2] == "confirm":
        generate_confirmation(out, int(sys.argv[3]), int(sys.argv[4]),
                              int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]))
    else:
        generate_survey(out)
```

### 10.3 gate2b-verify-input-metadata.py (Rev 14)

Change from Rev 13: RIFF parser uses exact size check (`!= len(data)`).

```python
#!/usr/bin/env python3
"""gate2b-verify-input-metadata.py — structural metadata verification (Rev 14).
Usage:
  python3 gate2b-verify-input-metadata.py jpeg <path>
  python3 gate2b-verify-input-metadata.py webp <path>
Exit 0 if all required families present; exit 1 otherwise.
"""
import sys, os, struct

# ---------------------------------------------------------------------------
# JPEG marker parser
# ---------------------------------------------------------------------------
_STANDALONE = frozenset(
    [bytes([0xff, b]) for b in ([0xd8, 0xd9, 0x01] + list(range(0xd0, 0xd8)))]
)

def _parse_jpeg_markers(data: bytes) -> dict:
    if data[:2] != b"\xff\xd8":
        raise ValueError("Not a JPEG")
    pos = 2
    out: dict = {}
    while pos < len(data) - 1:
        if data[pos] != 0xff:
            break
        while pos < len(data) and data[pos] == 0xff:
            pos += 1
        if pos >= len(data):
            break
        mtype = data[pos]; pos += 1
        marker = bytes([0xff, mtype])
        if marker in _STANDALONE:
            continue
        if mtype == 0xda:
            break
        if pos + 2 > len(data):
            break
        length = struct.unpack(">H", data[pos:pos+2])[0]
        if length < 2:
            break
        seg = data[pos+2:pos+length]
        out.setdefault(marker, []).append(seg)
        pos += length
    return out

# ---------------------------------------------------------------------------
# RIFF/WebP chunk parser — exact size required (no trailing bytes)
# ---------------------------------------------------------------------------
def _parse_riff_chunks(data: bytes) -> dict:
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        raise ValueError("Not a RIFF/WEBP container")
    file_size = struct.unpack("<I", data[4:8])[0]
    if file_size + 8 != len(data):
        raise ValueError(
            f"RIFF declared size {file_size} implies total {file_size+8}B "
            f"but actual length is {len(data)}B")
    pos = 12
    out: dict = {}
    while pos + 8 <= len(data):
        tag  = data[pos:pos+4]
        size = struct.unpack("<I", data[pos+4:pos+8])[0]
        if pos + 8 + size > len(data):
            raise ValueError(
                f"Chunk {tag!r} at offset {pos} claims {size}B but only "
                f"{len(data)-pos-8} remain")
        out.setdefault(tag, []).append(data[pos+8:pos+8+size])
        pos += 8 + size + (size & 1)
    return out

# ---------------------------------------------------------------------------
# JPEG family checkers
# ---------------------------------------------------------------------------
_EXIF_HDR = b"Exif\x00\x00"
_XMP_NS   = b"http://ns.adobe.com/xap/1.0/\x00"
_ICC_HDR  = b"ICC_PROFILE\x00"

def _jpeg_has_exif(markers: dict) -> bool:
    return any(s.startswith(_EXIF_HDR) for s in markers.get(b"\xff\xe1", []))

def _jpeg_has_xmp(markers: dict) -> bool:
    return any(s.startswith(_XMP_NS) for s in markers.get(b"\xff\xe1", []))

def _jpeg_has_icc(markers: dict) -> bool:
    return any(s.startswith(_ICC_HDR) for s in markers.get(b"\xff\xe2", []))

def _jpeg_has_comment(markers: dict) -> bool:
    return bool(markers.get(b"\xff\xfe"))

def _jpeg_has_gps(markers: dict) -> bool:
    import piexif
    for seg in markers.get(b"\xff\xe1", []):
        if not seg.startswith(_EXIF_HDR):
            continue
        try:
            exif = piexif.load(seg)
            if exif.get("GPS"):
                return True
        except Exception:
            pass
    return False

def _jpeg_has_iptc(markers: dict) -> bool:
    PS_HDR = b"Photoshop 3.0\x00"
    for seg in markers.get(b"\xff\xed", []):
        if not seg.startswith(PS_HDR):
            continue
        p = len(PS_HDR)
        while p + 12 <= len(seg):
            if seg[p:p+4] != b"8BIM":
                break
            res_id = struct.unpack(">H", seg[p+4:p+6])[0]
            name_len = seg[p+6] if p+6 < len(seg) else 0
            name_total = 1 + name_len
            if name_total % 2:
                name_total += 1
            p += 6 + name_total
            if p + 4 > len(seg):
                break
            data_len = struct.unpack(">I", seg[p:p+4])[0]
            p += 4
            if res_id == 0x0404:
                return True
            p += data_len + (data_len & 1)
    return False

# ---------------------------------------------------------------------------
# WebP family checkers
# ---------------------------------------------------------------------------
def _webp_has_exif(chunks: dict) -> bool:
    return b"EXIF" in chunks

def _webp_has_icc(chunks: dict) -> bool:
    return b"ICCP" in chunks

def _webp_has_xmp(chunks: dict) -> bool:
    return b"XMP " in chunks

def _webp_has_gps(chunks: dict) -> bool:
    import piexif
    for exif_data in chunks.get(b"EXIF", []):
        for candidate in (exif_data, b"Exif\x00\x00" + exif_data):
            try:
                exif = piexif.load(candidate)
                if exif.get("GPS"):
                    return True
            except Exception:
                continue
    return False

# ---------------------------------------------------------------------------
# Verify functions
# ---------------------------------------------------------------------------
def verify_jpeg(path: str) -> bool:
    with open(path, "rb") as f:
        data = f.read()
    try:
        markers = _parse_jpeg_markers(data)
    except ValueError as e:
        print(f"FAIL {os.path.basename(path)}: {e}"); return False
    checks = {
        "EXIF":    _jpeg_has_exif(markers),
        "GPS":     _jpeg_has_gps(markers),
        "ICC":     _jpeg_has_icc(markers),
        "IPTC":    _jpeg_has_iptc(markers),
        "XMP":     _jpeg_has_xmp(markers),
        "COMMENT": _jpeg_has_comment(markers),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        print(f"FAIL {os.path.basename(path)}: missing families: {missing}")
        return False
    print(f"OK   {os.path.basename(path)}: all 6 families present")
    return True

def verify_webp(path: str) -> bool:
    with open(path, "rb") as f:
        data = f.read()
    try:
        chunks = _parse_riff_chunks(data)
    except ValueError as e:
        print(f"FAIL {os.path.basename(path)}: {e}"); return False
    checks = {
        "EXIF": _webp_has_exif(chunks),
        "ICC":  _webp_has_icc(chunks),
        "XMP":  _webp_has_xmp(chunks),
        "GPS":  _webp_has_gps(chunks),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        print(f"FAIL {os.path.basename(path)}: missing: {missing}")
        return False
    print(f"OK   {os.path.basename(path)}: EXIF+GPS, ICC, XMP present")
    return True

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(1)
    fmt, path = sys.argv[1], sys.argv[2]
    if not os.path.exists(path):
        print(f"FAIL: {path} not found"); sys.exit(1)
    ok = verify_jpeg(path) if fmt == "jpeg" else verify_webp(path)
    sys.exit(0 if ok else 1)
```

---

## Section 11 — Runner: gate2b-run-r14.sh

```bash
#!/usr/bin/env bash
# tools/image-spike/gate2b-run-r14.sh — Gate 2B Rev 14 test runner
# DISPOSABLE — Gate 2B only. Execute only after three-party approval of Rev 14.
#
# Usage: PROJECT_REF=hkfrbdpedrxmbsawnbpr ANON_KEY=yyy bash tools/image-spike/gate2b-run-r14.sh
# ANON_KEY is never written to disk, echoed, or logged.

set -uo pipefail

# ---------------------------------------------------------------------------
# Environment validation
# ---------------------------------------------------------------------------
APPROVED_PROJECT_REF="hkfrbdpedrxmbsawnbpr"
[[ -n "${PROJECT_REF:-}" ]] \
  || { echo "FATAL: PROJECT_REF not set" >&2; exit 1; }
[[ "$PROJECT_REF" == "$APPROVED_PROJECT_REF" ]] \
  || { echo "FATAL: PROJECT_REF must be '$APPROVED_PROJECT_REF'" >&2; exit 1; }
[[ -n "${ANON_KEY:-}" ]] \
  || { echo "FATAL: ANON_KEY not set" >&2; exit 1; }

# ---------------------------------------------------------------------------
# JWT preflight
# ---------------------------------------------------------------------------
python3 - <<'PYEOF' || { echo "FATAL: ANON_KEY failed JWT preflight" >&2; exit 1; }
import sys, base64, json, os, time

def b64url_decode(s: str) -> bytes:
    s += "=" * ((-len(s)) % 4)
    return base64.urlsafe_b64decode(s)

key = os.environ.get("ANON_KEY", "")
ref = os.environ.get("PROJECT_REF", "")
parts = key.split(".")
if len(parts) != 3:
    print(f"FATAL: {len(parts)} JWT segment(s), expected 3", file=sys.stderr); sys.exit(1)
if not parts[2]:
    print("FATAL: JWT signature segment empty", file=sys.stderr); sys.exit(1)
try:
    header = json.loads(b64url_decode(parts[0]))
except Exception as e:
    print(f"FATAL: JWT header decode: {e}", file=sys.stderr); sys.exit(1)
if header.get("alg") != "HS256":
    print(f"FATAL: alg='{header.get('alg')}', expected 'HS256'", file=sys.stderr); sys.exit(1)
try:
    payload = json.loads(b64url_decode(parts[1]))
except Exception as e:
    print(f"FATAL: JWT payload decode: {e}", file=sys.stderr); sys.exit(1)
if payload.get("role") != "anon":
    print(f"FATAL: role='{payload.get('role')}', expected 'anon'", file=sys.stderr); sys.exit(1)
jwt_ref = payload.get("ref", "")
if not jwt_ref:
    print("FATAL: JWT payload missing 'ref'", file=sys.stderr); sys.exit(1)
if jwt_ref != ref:
    print(f"FATAL: JWT ref='{jwt_ref}' != PROJECT_REF='{ref}'", file=sys.stderr); sys.exit(1)
exp = payload.get("exp")
if exp is None:
    print("FATAL: JWT payload missing 'exp'", file=sys.stderr); sys.exit(1)
try:
    exp_int = int(exp)
except (TypeError, ValueError):
    print(f"FATAL: exp non-integer: {exp!r}", file=sys.stderr); sys.exit(1)
if exp_int <= int(time.time()):
    print(f"FATAL: JWT expired (exp={exp_int})", file=sys.stderr); sys.exit(1)
print(f"JWT preflight: HS256, role=anon, ref={jwt_ref} ✓")
PYEOF

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WASM_SRC="$REPO_ROOT/tools/image-spike/magick.wasm"
WASM_DST="$REPO_ROOT/supabase/functions/_shared/magick.wasm"
CONFIG="$REPO_ROOT/supabase/config.toml"
SPIKE_DIR="$REPO_ROOT/supabase/functions/image-spike"
IMG_DIR="$REPO_ROOT/tools/image-spike/test-images-r14"
FIXTURES_PY="$SCRIPT_DIR/gate2b-fixtures-r14.py"
VERIFY_OUT_PY="$SCRIPT_DIR/gate2b-verify-metadata.py"
VERIFY_IN_PY="$SCRIPT_DIR/gate2b-verify-input-metadata.py"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="$REPO_ROOT/tools/image-spike/gate2b-evidence-r14-${TIMESTAMP}"
OUT_DIR="$RESULTS_DIR/responses"
RESULTS_MD="$RESULTS_DIR/gate2b-results.md"
FUNC_URL="https://${PROJECT_REF}.supabase.co/functions/v1/image-spike"

MEM_THRESHOLD_MIB=200
CPU_THRESHOLD_MS=1500
SURVEY_PIXEL_LIMIT=15500000

declare -a SURVEY_FIXTURES=(
  "S-5|test-S-5.jpg|2500|2000|5000000|4000000|5500000"
  "S-8|test-S-8.jpg|4000|2000|8000000|6500000|9000000"
  "S-10|test-S-10.jpg|4000|2500|10000000|8500000|10000000"
  "S-12|test-S-12.jpg|4000|3000|12000000|9000000|10000000"
  "S-15|test-S-15.jpg|5000|3000|15000000|9000000|10000000"
)
declare -A SURVEY_DIMS=(
  [5]="2500 2000 5000000" [8]="4000 2000 8000000"
  [10]="4000 2500 10000000" [12]="4000 3000 12000000"
  [15]="5000 3000 15000000"
)
declare -A SURVEY_BANDS=(
  [5]="4000000 5500000" [8]="6500000 9000000"
  [10]="8500000 10000000" [12]="9000000 10000000"
  [15]="9000000 10000000"
)
declare -a SURVEY_MP_ORDER=(5 8 10 12 15)

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
CLEANUP_RAN=false
REMOTE_CLEANUP_REQUIRED=false
WASM_COPIED=false
CONFIG_PATCHED=false
REMOTE_DELETE_FAILED=false
GATE2B_PASS=true
declare -a FAIL_REASONS=()
LAST_WALL_TIME=""
LAST_RUN_ID=""
LAST_INVOKE_546=false

declare -A SURVEY_CPU=()
declare -A SURVEY_MEM=()
declare -A SURVEY_REASON=()
declare -A SURVEY_FUNC_PASS=()
declare -A SURVEY_TELEM_OK=()

# Global used by survey_telemetry_result — avoids subshell
SURVEY_TELEM_OUTCOME=""

CHOSEN_MP=""
CHOSEN_W=0; CHOSEN_H=0; CHOSEN_PX=0
CHOSEN_MIN_B=0; CHOSEN_MAX_B=0
REJECT_W=0; REJECT_PX=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
fail() {
  GATE2B_PASS=false
  FAIL_REASONS+=("$*")
  echo "FAILURE: $*" >&2
}
results_append() { printf '%s\n' "$*" >> "$RESULTS_MD"; }
bool_field() {
  jq -r --arg f "$2" \
    'if has($f) and (.[$f]|type)=="boolean" then (.[$f]|tostring) else "MISSING" end' \
    "$1" 2>/dev/null || echo "PARSE_ERROR"
}
is_valid_uuid() {
  echo "$1" | grep -qiE \
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
  [[ "$CLEANUP_RAN" == "true" ]] && return
  CLEANUP_RAN=true
  local trigger="${1:-EXIT}"
  echo "" >&2; echo "=== Gate 2B Rev 14 Cleanup (trigger: $trigger) ===" >&2
  if [[ "$REMOTE_CLEANUP_REQUIRED" == "true" ]]; then
    supabase functions delete image-spike --project-ref "$PROJECT_REF" 2>/dev/null || true
    sleep 3
    local lo le
    lo=$(supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null); le=$?
    if [[ $le -ne 0 ]]; then
      echo "WARNING: functions list failed" >&2; REMOTE_DELETE_FAILED=true
    elif printf '%s' "$lo" | grep -q "image-spike"; then
      echo "WARNING: image-spike still listed — manual deletion required" >&2
      REMOTE_DELETE_FAILED=true
    else
      echo "Cleanup: remote deletion confirmed" >&2; REMOTE_CLEANUP_REQUIRED=false
    fi
  fi
  if [[ "$CONFIG_PATCHED" == "true" ]] \
     || grep -q '\[functions\.image-spike\]' "$CONFIG" 2>/dev/null; then
    python3 - "$CONFIG" <<'PYEOF'
import re, sys
p = sys.argv[1]
with open(p) as f: c = f.read()
with open(p,'w') as f:
    f.write(re.sub(r'\n\[functions\.image-spike\]\n(?:(?!\[)[^\n]*\n)*','\n',c))
print('config.toml cleaned', file=sys.stderr)
PYEOF
  fi
  [[ -f "$WASM_DST" ]]  && rm "$WASM_DST"     && echo "Removed: $WASM_DST" >&2
  [[ -d "$SPIKE_DIR" ]] && rm -rf "$SPIKE_DIR" && echo "Removed: $SPIKE_DIR" >&2
  [[ -d "$IMG_DIR" ]]   && rm -rf "$IMG_DIR"   && echo "Removed: $IMG_DIR" >&2
  echo "Evidence preserved in: $RESULTS_DIR" >&2
  [[ "$REMOTE_DELETE_FAILED" == "true" ]] \
    && { echo "CRITICAL: Remote deletion unconfirmed — manual action required." >&2; exit 1; }
}
trap 'cleanup EXIT' EXIT
trap 'GATE2B_PASS=false; FAIL_REASONS+=("INTERRUPTED:INT"); cleanup INT; exit 130' INT
trap 'GATE2B_PASS=false; FAIL_REASONS+=("INTERRUPTED:TERM"); cleanup TERM; exit 143' TERM

# ---------------------------------------------------------------------------
# deploy_function
# ---------------------------------------------------------------------------
deploy_function() {
  local phase="$1"
  echo ""; echo "=== Phase $phase: Deploy image-spike ==="
  local pl pe
  pl=$(supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null); pe=$?
  [[ $pe -eq 0 ]] || { fail "Phase $phase: pre-deploy list failed ($pe)"; return 1; }
  printf '%s' "$pl" | grep -q "image-spike" \
    && { fail "Phase $phase: image-spike already exists on remote"; return 1; }
  REMOTE_CLEANUP_REQUIRED=true
  local dout
  dout=$(supabase functions deploy image-spike \
    --project-ref "$PROJECT_REF" --debug 2>&1)
  local de=$?
  echo "$dout"
  [[ $de -eq 0 ]] || { fail "Phase $phase: deploy failed (exit $de)"; return 1; }
  local braw
  braw=$(python3 - "$dout" <<'PYEOF'
import sys, re
m = re.search(r'(?:script|bundle) size:\s*([0-9]+(?:\.[0-9]+)?)\s*(MiB|MB)\b',
              sys.argv[1], re.IGNORECASE)
if m: print(m.group(1) + " " + m.group(2))
PYEOF
)
  [[ -n "$braw" ]] || {
    fail "Phase $phase: bundle size not found in --debug output"
    results_append "Phase $phase bundle: UNPARSEABLE"; return 1; }
  python3 - "$braw" <<'PYEOF' || { fail "Phase $phase: bundle ${braw} > 20 MB"; return 1; }
import sys, math
p=sys.argv[1].split(); n,u=float(p[0]),p[1].upper()
mb=n*1.048576 if u=="MIB" else n
if not (math.isfinite(mb) and mb>=0): print(f"FAIL"); sys.exit(1)
if mb>20: print(f"FAIL: {sys.argv[1]} = {mb:.2f} MB > 20 MB"); sys.exit(1)
print(f"bundle: {sys.argv[1]} = {mb:.2f} MB ≤ 20 MB ✓")
PYEOF
  results_append "Phase $phase bundle: ${braw}"
}

# ---------------------------------------------------------------------------
# delete_confirmed
# ---------------------------------------------------------------------------
delete_confirmed() {
  local phase="$1"
  supabase functions delete image-spike --project-ref "$PROJECT_REF" 2>/dev/null || true
  sleep 3
  local lo le
  lo=$(supabase functions list --project-ref "$PROJECT_REF" 2>/dev/null); le=$?
  [[ $le -eq 0 ]] || { fail "Phase $phase: functions list failed ($le)"; REMOTE_DELETE_FAILED=true; return 1; }
  printf '%s' "$lo" | grep -q "image-spike" \
    && { fail "Phase $phase: image-spike still listed after delete"; REMOTE_DELETE_FAILED=true; return 1; }
  echo "Phase $phase deletion: confirmed ✓"; REMOTE_CLEANUP_REQUIRED=false
}

# ---------------------------------------------------------------------------
# invoke_case
# Returns: 0 = completed; 2 = HTTP 546. Never calls fail() on 546.
# ---------------------------------------------------------------------------
invoke_case() {
  LAST_RUN_ID=""
  LAST_INVOKE_546=false

  local label="$1" filename="$2" mime="$3" exp_accepted="$4" exp_reason="$5"
  local exp_w="$6" exp_h="$7" exp_pixels="$8"
  local img="$IMG_DIR/$filename"
  local out="$OUT_DIR/${label}.json" hdr="$OUT_DIR/${label}.headers"
  local webp_out="$OUT_DIR/${label}_output.webp"
  local actual_input_size
  actual_input_size=$(wc -c < "$img" | awk '{print $1}')

  echo ""; echo "--- $label ($filename, $mime) ---"
  local curl_w
  curl_w=$(curl -s -o "$out" -D "$hdr" -w '%{http_code}\t%{time_total}' \
    --max-time 120 -X POST "${FUNC_URL}?label=${label}" \
    -H "Authorization: Bearer $ANON_KEY" \
    -H "Content-Type: $mime" --data-binary "@$img" 2>/dev/null)
  local curl_exit=$?

  local http_status wall_time req_id
  http_status=$(printf '%s' "$curl_w" | awk -F'\t' '{print $1}')
  wall_time=$(printf '%s'   "$curl_w" | awk -F'\t' '{print $2}')
  LAST_WALL_TIME="$wall_time"
  req_id=$(grep -i '^x-request-id:' "$hdr" 2>/dev/null \
    | awk '{print $2}' | tr -d '\r' | head -1 || true)

  echo "  curl_exit=$curl_exit  HTTP=$http_status  wall_time=${wall_time}s"
  results_append ""; results_append "### $label"
  results_append "curl_exit=$curl_exit  HTTP=$http_status  wall_time_s=$wall_time"
  results_append "x-request-id: ${req_id:-<not found>}"

  if [[ $curl_exit -ne 0 ]]; then
    fail "$label: curl exit $curl_exit"; results_append "FAIL: curl transport error"; return 0; fi
  if [[ "$http_status" == "546" ]]; then
    results_append "HTTP 546 — resource limit boundary"
    LAST_INVOKE_546=true; return 2
  fi
  if [[ "$http_status" == "401" || "$http_status" == "403" ]]; then
    fail "$label: HTTP $http_status — authentication failure"
    results_append "HARD FAIL: HTTP $http_status"; exit 1; fi
  if [[ "$http_status" != "200" ]]; then
    fail "$label: HTTP $http_status"; results_append "FAIL: HTTP $http_status"; return 0; fi

  local resp_label
  resp_label=$(jq -r '.label // "MISSING"' "$out" 2>/dev/null || echo "PARSE_ERROR")
  [[ "$resp_label" == "$label" ]] || fail "$label: response label='$resp_label' ≠ '$label'"

  local resp_run_id
  resp_run_id=$(jq -r '.run_id // ""' "$out" 2>/dev/null || echo "")
  LAST_RUN_ID="$resp_run_id"
  results_append "run_id: ${resp_run_id:-MISSING}"
  is_valid_uuid "$resp_run_id" || fail "$label: run_id '${resp_run_id}' not a valid UUID"

  local resp_accepted
  resp_accepted=$(bool_field "$out" "accepted")
  if [[ "$resp_accepted" == "MISSING" || "$resp_accepted" == "PARSE_ERROR" ]]; then
    fail "$label: accepted field missing"
  elif [[ "$resp_accepted" != "$exp_accepted" ]]; then
    fail "$label: accepted=$resp_accepted ≠ $exp_accepted"
  fi

  local resp_w resp_h resp_pixels
  resp_w=$(jq -r '.width // 0'        "$out" 2>/dev/null || echo 0)
  resp_h=$(jq -r '.height // 0'       "$out" 2>/dev/null || echo 0)
  resp_pixels=$(jq -r '.pixel_count // 0' "$out" 2>/dev/null || echo 0)
  [[ "$resp_w" == "$exp_w" && "$resp_h" == "$exp_h" ]] \
    || fail "$label: dimensions ${resp_w}x${resp_h} ≠ ${exp_w}x${exp_h}"
  [[ "$resp_pixels" == "$exp_pixels" ]] \
    || fail "$label: pixel_count=$resp_pixels ≠ $exp_pixels"

  local resp_decode_started
  resp_decode_started=$(bool_field "$out" "image_decode_started")
  if [[ "$resp_decode_started" == "MISSING" || "$resp_decode_started" == "PARSE_ERROR" ]]; then
    fail "$label: image_decode_started missing"
  elif [[ "$exp_accepted" == "false" && "$resp_decode_started" != "false" ]]; then
    fail "$label: image_decode_started=$resp_decode_started ≠ false"
  elif [[ "$exp_accepted" == "true" && "$resp_decode_started" != "true" ]]; then
    fail "$label: image_decode_started=$resp_decode_started ≠ true"
  fi
  results_append "image_decode_started: $resp_decode_started"

  if [[ "$exp_accepted" == "false" ]]; then
    local resp_reason
    resp_reason=$(jq -r '.reason // "MISSING"' "$out" 2>/dev/null || echo "PARSE_ERROR")
    [[ "$resp_reason" == "$exp_reason" ]] \
      || fail "$label: reason='$resp_reason' ≠ '$exp_reason'"
    results_append "accepted=false  reason=$resp_reason"; return 0
  fi

  local resp_input_size
  resp_input_size=$(jq -r '.input_size_bytes // 0' "$out" 2>/dev/null || echo 0)
  [[ "$resp_input_size" == "$actual_input_size" ]] \
    || fail "$label: input_size_bytes=$resp_input_size ≠ $actual_input_size"
  [[ "$(bool_field "$out" "metadata_clean")" == "true" ]] \
    || fail "$label: metadata_clean ≠ true"

  local resp_sha256
  resp_sha256=$(jq -r '.sha256 // ""' "$out" 2>/dev/null || echo "")
  printf '%s' "$resp_sha256" | grep -qE '^[0-9a-f]{64}$' \
    || fail "$label: sha256 format invalid"

  local resp_output_b64
  resp_output_b64=$(jq -r '.output_bytes // ""' "$out" 2>/dev/null || echo "")
  if [[ -z "$resp_output_b64" || "$resp_output_b64" == "null" ]]; then
    fail "$label: output_bytes absent"
  elif printf '%s' "$resp_output_b64" | base64 -d > "$webp_out" 2>/dev/null; then
    local decoded_size header_check actual_sha resp_output_size
    decoded_size=$(wc -c < "$webp_out" | awk '{print $1}')
    header_check=$(python3 -c "
with open('$webp_out','rb') as f: d=f.read(12)
print('valid' if d[:4]==b'RIFF' and d[8:12]==b'WEBP' else 'invalid')
" 2>/dev/null || echo "error")
    [[ "$header_check" == "valid" ]] || fail "$label: decoded output not valid WebP"
    actual_sha=$(shasum -a 256 "$webp_out" | awk '{print $1}')
    [[ "$actual_sha" == "$resp_sha256" ]] \
      || fail "$label: SHA-256 mismatch (recomputed=$actual_sha)"
    resp_output_size=$(jq -r '.output_size_bytes // 0' "$out" 2>/dev/null || echo 0)
    [[ "$resp_output_size" == "$decoded_size" ]] \
      || fail "$label: output_size_bytes=$resp_output_size ≠ $decoded_size"
    python3 "$VERIFY_OUT_PY" "$webp_out" 2>&1 \
      || fail "$label: RIFF parser found metadata or malformed WebP"
  else
    fail "$label: base64 decode failed"
  fi

  results_append "sha256: $resp_sha256  wall_time_s=$wall_time"
  return 0
}

# ---------------------------------------------------------------------------
# Telemetry input capture (shared by both survey and confirmation functions)
# ---------------------------------------------------------------------------
OK_REASONS="EventLoopCompleted EarlyDrop TerminationRequested"
RESOURCE_REASONS="Memory CPUTime WallClockTime"
TELEM_EXEC_ID="" TELEM_CPU="" TELEM_MEM="" TELEM_REASON=""

telemetry_gate() {
  local label="$1" run_id="$2"
  echo ""
  echo "================================================================="
  echo "$label TELEMETRY CAPTURE GATE"
  echo "run_id: ${run_id:-MISSING}"
  echo "STEP 1: Log Explorer → filter function_id='image-spike' → search run_id → record execution_id"
  echo "STEP 2: Search execution_id → find ShutdownEvent → extract:"
  echo "        cpu_time_used (ms), memory_used.total (bytes), reason"
  echo "Enter INCONCLUSIVE for any missing field."
  echo "================================================================="
  read -rp "$label execution_id (UUID or INCONCLUSIVE): " TELEM_EXEC_ID
  read -rp "$label cpu_time_used ms (or INCONCLUSIVE): "  TELEM_CPU
  read -rp "$label memory_used.total bytes (or INCONCLUSIVE): " TELEM_MEM
  read -rp "$label shutdown_reason (or INCONCLUSIVE): "   TELEM_REASON
}

# ---------------------------------------------------------------------------
# survey_telemetry_result — runs in PARENT SHELL (no command substitution).
# Sets global SURVEY_TELEM_OUTCOME to "pass", "nonviable", or "evidence_fail".
# Calls fail() only on evidence_fail; never calls fail() for nonviable.
# Caller must check SURVEY_TELEM_OUTCOME after calling this function.
# ---------------------------------------------------------------------------
survey_telemetry_result() {
  local label="$1"
  SURVEY_TELEM_OUTCOME=""   # reset global

  results_append "#### $label Telemetry (survey)"
  results_append "exec_id: $TELEM_EXEC_ID  cpu: $TELEM_CPU  mem: $TELEM_MEM  reason: $TELEM_REASON"

  # Step 1: INCONCLUSIVE check
  if [[ "$TELEM_EXEC_ID" == "INCONCLUSIVE" || "$TELEM_CPU" == "INCONCLUSIVE" \
        || "$TELEM_MEM" == "INCONCLUSIVE" || "$TELEM_REASON" == "INCONCLUSIVE" ]]; then
    fail "$label: survey telemetry INCONCLUSIVE — evidence quality failure"
    SURVEY_TELEM_OUTCOME="evidence_fail"; return
  fi

  # Step 2: UUID validation
  if ! is_valid_uuid "$TELEM_EXEC_ID"; then
    fail "$label: execution_id '${TELEM_EXEC_ID}' not a valid UUID — evidence quality failure"
    SURVEY_TELEM_OUTCOME="evidence_fail"; return
  fi

  # Step 3 & 4: Numeric validation of CPU and memory BEFORE reason classification
  local numeric_ok
  numeric_ok=$(python3 - "$TELEM_CPU" "$TELEM_MEM" <<'PYEOF'
import sys, math
try:
    cpu = float(sys.argv[1])
    mem = float(sys.argv[2])
except ValueError as e:
    print(f"FAIL:non-numeric:{e}"); sys.exit(0)
if not (math.isfinite(cpu) and cpu >= 0):
    print(f"FAIL:cpu-non-finite:{sys.argv[1]}"); sys.exit(0)
if not (math.isfinite(mem) and mem >= 0):
    print(f"FAIL:mem-non-finite:{sys.argv[2]}"); sys.exit(0)
print("OK")
PYEOF
  )
  if [[ "${numeric_ok%%:*}" != "OK" ]]; then
    fail "$label: telemetry field invalid — ${numeric_ok} — evidence quality failure"
    SURVEY_TELEM_OUTCOME="evidence_fail"; return
  fi

  # Step 5: Reason must be in recognized set (OK ∪ RESOURCE)
  if ! echo "$OK_REASONS $RESOURCE_REASONS" | grep -qw "${TELEM_REASON:-}"; then
    fail "$label: shutdown_reason='$TELEM_REASON' — unrecognized; cannot classify level"
    SURVEY_TELEM_OUTCOME="evidence_fail"; return
  fi

  # Step 6: Classification — all fields are valid; now determine viability
  if echo "$RESOURCE_REASONS" | grep -qw "${TELEM_REASON:-}"; then
    results_append "$label: nonviable (resource-limit reason: $TELEM_REASON)"
    SURVEY_TELEM_OUTCOME="nonviable"; return
  fi

  # Threshold check
  local threshold_result
  threshold_result=$(python3 - "$TELEM_CPU" "$TELEM_MEM" "$MEM_THRESHOLD_MIB" "$CPU_THRESHOLD_MS" <<'PYEOF'
import sys, math
cpu_r,mem_r,mt,ct = sys.argv[1:]
cpu=float(cpu_r); mem=float(mem_r); mt=float(mt); ct=float(ct)
mib=mem/1_048_576
if cpu>ct or mib>mt:
    print(f"nonviable:cpu={cpu:.0f}ms,mem={mib:.1f}MiB")
else:
    print(f"pass:cpu={cpu:.0f}ms,mem={mib:.1f}MiB")
PYEOF
  )
  if [[ "${threshold_result%%:*}" == "nonviable" ]]; then
    results_append "$label: nonviable — ${threshold_result#*:}"
    SURVEY_TELEM_OUTCOME="nonviable"
  else
    results_append "$label: pass — ${threshold_result#*:}"
    SURVEY_TELEM_OUTCOME="pass"
  fi
}

# ---------------------------------------------------------------------------
# confirmation_telemetry_result — any failure calls fail()
# ---------------------------------------------------------------------------
confirmation_telemetry_result() {
  local label="$1"
  results_append "#### $label Telemetry (confirmation)"
  results_append "exec_id: $TELEM_EXEC_ID  cpu: $TELEM_CPU  mem: $TELEM_MEM  reason: $TELEM_REASON"

  if [[ "$TELEM_EXEC_ID" == "INCONCLUSIVE" || "$TELEM_CPU" == "INCONCLUSIVE" \
        || "$TELEM_MEM" == "INCONCLUSIVE" || "$TELEM_REASON" == "INCONCLUSIVE" ]]; then
    fail "$label: confirmation telemetry INCONCLUSIVE"; return 1; fi
  is_valid_uuid "$TELEM_EXEC_ID" \
    || { fail "$label: execution_id '${TELEM_EXEC_ID}' not valid UUID"; return 1; }

  local numeric_ok
  numeric_ok=$(python3 - "$TELEM_CPU" "$TELEM_MEM" <<'PYEOF'
import sys, math
try:
    cpu=float(sys.argv[1]); mem=float(sys.argv[2])
except ValueError as e:
    print(f"FAIL:{e}"); sys.exit(0)
if not (math.isfinite(cpu) and cpu>=0) or not (math.isfinite(mem) and mem>=0):
    print("FAIL:non-finite"); sys.exit(0)
print("OK")
PYEOF
  )
  [[ "${numeric_ok%%:*}" == "OK" ]] \
    || { fail "$label: telemetry numeric invalid — $numeric_ok"; return 1; }

  if echo "$RESOURCE_REASONS" | grep -qw "${TELEM_REASON:-}"; then
    fail "$label: shutdown_reason='$TELEM_REASON' — resource-limit exceeded"; return 1; fi
  if ! echo "$OK_REASONS" | grep -qw "${TELEM_REASON:-}"; then
    fail "$label: shutdown_reason='$TELEM_REASON' — unrecognized"; return 1; fi

  python3 - "$TELEM_CPU" "$TELEM_MEM" "$MEM_THRESHOLD_MIB" "$CPU_THRESHOLD_MS" "$label" <<'PYEOF'
import sys, math
cpu_r,mem_r,mt,ct,lbl=sys.argv[1:]
cpu=float(cpu_r); mem=float(mem_r); mt=float(mt); ct=float(ct)
mib=mem/1_048_576
print(f"cpu={cpu:.0f}ms ({'≤' if cpu<=ct else '>'}{ct:.0f}) {'✓' if cpu<=ct else 'FAIL'}")
print(f"mem={mib:.1f}MiB ({'≤' if mib<=mt else '>'}{mt:.0f}) {'✓' if mib<=mt else 'FAIL'}")
if cpu>ct or mib>mt: sys.exit(2)
print(f"{lbl}: confirmation telemetry PASS")
PYEOF
  local te=$?
  [[ $te -eq 0 ]] || { fail "$label: confirmation telemetry threshold exceeded"; return 1; }
  results_append "$label: PASS"; return 0
}

# ---------------------------------------------------------------------------
# update_pixel_limit
# ---------------------------------------------------------------------------
update_pixel_limit() {
  python3 - "$SPIKE_DIR/index.ts" "$1" <<'PYEOF' \
    || { echo "FATAL: update_pixel_limit failed" >&2; exit 1; }
import sys, re
path, limit = sys.argv[1], sys.argv[2]
with open(path) as f: content = f.read()
new, n = re.subn(r'(CANONICAL_PIXEL_LIMIT\s*=\s*)[\d_]+', rf'\g<1>{limit}', content)
if n != 1:
    print(f"FATAL: expected 1 substitution, got {n}", file=sys.stderr); sys.exit(1)
with open(path,'w') as f: f.write(new)
print(f"CANONICAL_PIXEL_LIMIT → {limit} (1 substitution ✓)")
PYEOF
}

# ===========================================================================
# PREFLIGHT
# ===========================================================================
echo "=== Gate 2B Rev 14 Preflight ==="
for tool in supabase curl jq python3 shasum deno gitleaks; do
  command -v "$tool" &>/dev/null || { echo "FATAL: $tool not found" >&2; exit 1; }
done

REV9_EVIDENCE="$REPO_ROOT/tools/image-spike/gate2b-evidence-20260814T194105Z/gate2b-results.md"
REV9_SHA="3903f9dc08bb7edc77720911a614a9656ad97b5c9e42a04c9a50d60f3fd1bc4f"
[[ -f "$REV9_EVIDENCE" ]] || { echo "FATAL: Rev 9 evidence missing" >&2; exit 1; }
[[ "$(shasum -a 256 "$REV9_EVIDENCE" | awk '{print $1}')" == "$REV9_SHA" ]] \
  || { echo "FATAL: Rev 9 evidence SHA mismatch" >&2; exit 1; }
echo "Rev 9 evidence SHA: verified ✓"

for f in "$WASM_SRC" "$VERIFY_OUT_PY" "$VERIFY_IN_PY" "$FIXTURES_PY"; do
  [[ -f "$f" ]] || { echo "FATAL: file not found: $f" >&2; exit 1; }
done
[[ -d "$SPIKE_DIR" ]] || { echo "FATAL: spike dir not found" >&2; exit 1; }
[[ -d "$IMG_DIR" ]]     && { echo "FATAL: IMG_DIR exists" >&2; exit 1; }
[[ -d "$RESULTS_DIR" ]] && { echo "FATAL: RESULTS_DIR collision" >&2; exit 1; }
[[ -f "$WASM_DST" ]]    && { echo "FATAL: $WASM_DST exists" >&2; exit 1; }
grep -q '\[functions\.image-spike\]' "$CONFIG" 2>/dev/null \
  && { echo "FATAL: [functions.image-spike] already in config.toml" >&2; exit 1; }

python3 - "$SPIKE_DIR/index.ts" "$SURVEY_PIXEL_LIMIT" <<'PYEOF' \
  || { echo "FATAL: CANONICAL_PIXEL_LIMIT mismatch" >&2; exit 1; }
import sys, re
path, expected = sys.argv[1], sys.argv[2].replace("_","")
with open(path) as f: content = f.read()
m = re.search(r'CANONICAL_PIXEL_LIMIT\s*=\s*([\d_]+)', content)
if not m: print("FATAL: not found", file=sys.stderr); sys.exit(1)
actual = m.group(1).replace("_","")
if actual != expected:
    print(f"FATAL: got {actual}, expected {expected}", file=sys.stderr); sys.exit(1)
print(f"CANONICAL_PIXEL_LIMIT={actual} ✓")
PYEOF

mkdir -p "$OUT_DIR"; > "$RESULTS_MD"
results_append "# Gate 2B Results — Rev 14"
results_append "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
results_append "PROJECT_REF: $PROJECT_REF"
results_append "MEM_THRESHOLD_MIB: $MEM_THRESHOLD_MIB  CPU_THRESHOLD_MS: $CPU_THRESHOLD_MS"
echo "Preflight: all checks passed"

# ===========================================================================
# GENERATE + VERIFY SURVEY FIXTURES
# ===========================================================================
echo ""; echo "=== Generating survey fixtures ==="
python3 "$FIXTURES_PY" "$IMG_DIR" || { echo "FATAL: survey fixture gen failed" >&2; exit 1; }

echo ""; echo "=== Verifying survey fixtures ==="
results_append ""; results_append "## Fixture Preflight"
preflight_ok=true
for entry in "${SURVEY_FIXTURES[@]}"; do
  IFS="|" read -r sid filename exp_w exp_h exp_pixels min_bytes max_bytes <<< "$entry"
  img="$IMG_DIR/$filename"
  [[ -f "$img" ]] || { echo "FATAL: $img missing" >&2; exit 1; }
  byte_size=$(wc -c < "$img" | awk '{print $1}')
  sha=$(shasum -a 256 "$img" | awk '{print $1}')
  dims=$(python3 -c "
from PIL import Image
with Image.open('$img') as im: print(im.width, im.height)
" 2>/dev/null) || { echo "FATAL: cannot read dims of $img" >&2; exit 1; }
  actual_w=$(echo "$dims"|awk '{print $1}'); actual_h=$(echo "$dims"|awk '{print $2}')
  actual_px=$((actual_w * actual_h))
  ok=true
  [[ "$actual_w" == "$exp_w" && "$actual_h" == "$exp_h" ]] \
    || { fail "PREFLIGHT $sid: dims ${actual_w}x${actual_h} ≠ ${exp_w}x${exp_h}"; ok=false; }
  [[ "$actual_px" == "$exp_pixels" ]] \
    || { fail "PREFLIGHT $sid: pixel_count $actual_px ≠ $exp_pixels"; ok=false; }
  python3 -c "import sys; sys.exit(0 if $min_bytes <= $byte_size <= $max_bytes else 1)" \
    || { fail "PREFLIGHT $sid: size $byte_size outside [$min_bytes,$max_bytes]"; ok=false; }
  [[ "$byte_size" -le 10000000 ]] \
    || { fail "PREFLIGHT $sid: size $byte_size > 10 MB upload ceiling"; ok=false; }
  python3 "$VERIFY_IN_PY" jpeg "$img" \
    || { fail "PREFLIGHT $sid: metadata families missing"; ok=false; }
  [[ "$ok" == "true" ]] || preflight_ok=false
  results_append "$sid: $filename ${byte_size}B ${actual_w}x${actual_h} sha256=${sha}"
  echo "PREFLIGHT $sid: ${byte_size}B ${actual_w}x${actual_h} $([[ "$ok" == "true" ]] && echo ✓ || echo FAIL)"
done
[[ "$preflight_ok" == "true" && "$GATE2B_PASS" == "true" ]] \
  || { echo "FATAL: fixture preflight failed" >&2; exit 1; }

# ===========================================================================
# WASM + CONFIG + STATIC CHECKS
# ===========================================================================
cp "$WASM_SRC" "$WASM_DST"
SRC_HASH=$(shasum -a 256 "$WASM_SRC" | awk '{print $1}')
[[ "$(shasum -a 256 "$WASM_DST" | awk '{print $1}')" == "$SRC_HASH" ]] \
  || { echo "FATAL: WASM hash mismatch" >&2; exit 1; }
WASM_COPIED=true
INDEX_HASH=$(shasum -a 256 "$SPIKE_DIR/index.ts" | awk '{print $1}')
results_append ""; results_append "## Hashes"
results_append "magick.wasm sha256: $SRC_HASH"
results_append "index.ts (survey) sha256: $INDEX_HASH"

printf '\n[functions.image-spike]\nstatic_files = ["./functions/_shared/magick.wasm"]\n' >> "$CONFIG"
CONFIG_PATCHED=true

deno fmt --check "$SPIKE_DIR/index.ts" || { fail "deno fmt"; exit 1; }
deno lint "$SPIKE_DIR/index.ts"        || { fail "deno lint"; exit 1; }
deno check "$SPIKE_DIR/index.ts"       || { fail "deno check"; exit 1; }
gitleaks detect --source "$REPO_ROOT" --config "$REPO_ROOT/.gitleaks.toml" 2>/dev/null \
  || { fail "gitleaks"; exit 1; }
echo "Static checks passed"

read -rp "Type YES to confirm pre-deployment three-party approval: " _confirm
[[ "$_confirm" == "YES" ]] || { echo "Deployment aborted." >&2; exit 1; }

# ===========================================================================
# SURVEY PHASES
# ===========================================================================
results_append ""; results_append "## Survey Phase Results"

for mp in "${SURVEY_MP_ORDER[@]}"; do
  phase_label="S-${mp}MP"
  read -r exp_w exp_h exp_pixels <<< "${SURVEY_DIMS[$mp]}"
  sid="S-${mp}"; filename="test-S-${mp}.jpg"

  results_append ""; results_append "### Phase $phase_label"
  echo ""; echo "=== SURVEY PHASE $phase_label ==="

  deploy_function "$phase_label" || exit 1

  pre_func_fails=${#FAIL_REASONS[@]}

  invoke_case "$sid" "$filename" "image/jpeg" "true" "" "$exp_w" "$exp_h" "$exp_pixels"
  invoke_exit=$?
  phase_run_id="$LAST_RUN_ID"; phase_wall="$LAST_WALL_TIME"

  if [[ $invoke_exit -eq 2 ]]; then
    echo "Phase $phase_label: HTTP 546 — stopping survey ascent"
    results_append "Phase $phase_label: 546 boundary — survey stopped"
    SURVEY_FUNC_PASS[$mp]="false"
    SURVEY_TELEM_OK[$mp]="false"
    SURVEY_CPU[$mp]=""; SURVEY_MEM[$mp]=""; SURVEY_REASON[$mp]="546"
    delete_confirmed "$phase_label" || exit 1
    break
  fi

  python3 -c "import sys; sys.exit(0 if float('$phase_wall') <= 30 else 1)" \
    || fail "$sid: cold wall-clock ${phase_wall}s > 30 s"
  results_append "$sid cold_wall_time_s: $phase_wall"

  post_func_fails=${#FAIL_REASONS[@]}
  if [[ $((post_func_fails - pre_func_fails)) -eq 0 ]]; then
    SURVEY_FUNC_PASS[$mp]="true"
  else
    SURVEY_FUNC_PASS[$mp]="false"
  fi

  delete_confirmed "$phase_label" || exit 1

  telemetry_gate "$sid" "$phase_run_id"

  # Call directly — NOT in $() — so fail() propagates to parent shell
  survey_telemetry_result "$sid"

  SURVEY_CPU[$mp]="${TELEM_CPU}"
  SURVEY_MEM[$mp]="${TELEM_MEM}"
  SURVEY_REASON[$mp]="${TELEM_REASON}"

  if [[ "$SURVEY_TELEM_OUTCOME" == "evidence_fail" ]]; then
    # fail() was already called inside survey_telemetry_result
    echo "FATAL: survey telemetry evidence failure at $sid — stopping run" >&2
    exit 1
  elif [[ "$SURVEY_TELEM_OUTCOME" == "pass" ]]; then
    SURVEY_TELEM_OK[$mp]="true"
  else
    # nonviable
    SURVEY_TELEM_OK[$mp]="false"
  fi
done

# ===========================================================================
# CEILING SELECTION
# ===========================================================================
echo ""; echo "=== CEILING SELECTION ==="
results_append ""; results_append "## Ceiling Selection"

ceiling_output=$(python3 - \
  "${SURVEY_FUNC_PASS[5]:-false}"  "${SURVEY_TELEM_OK[5]:-false}"  "${SURVEY_CPU[5]:-}"  "${SURVEY_MEM[5]:-}"  "${SURVEY_REASON[5]:-}" \
  "${SURVEY_FUNC_PASS[8]:-false}"  "${SURVEY_TELEM_OK[8]:-false}"  "${SURVEY_CPU[8]:-}"  "${SURVEY_MEM[8]:-}"  "${SURVEY_REASON[8]:-}" \
  "${SURVEY_FUNC_PASS[10]:-false}" "${SURVEY_TELEM_OK[10]:-false}" "${SURVEY_CPU[10]:-}" "${SURVEY_MEM[10]:-}" "${SURVEY_REASON[10]:-}" \
  "${SURVEY_FUNC_PASS[12]:-false}" "${SURVEY_TELEM_OK[12]:-false}" "${SURVEY_CPU[12]:-}" "${SURVEY_MEM[12]:-}" "${SURVEY_REASON[12]:-}" \
  "${SURVEY_FUNC_PASS[15]:-false}" "${SURVEY_TELEM_OK[15]:-false}" "${SURVEY_CPU[15]:-}" "${SURVEY_MEM[15]:-}" "${SURVEY_REASON[15]:-}" \
  "$MEM_THRESHOLD_MIB" "$CPU_THRESHOLD_MS" <<'PYEOF'
import sys, math

args = sys.argv[1:]
MP = [5, 8, 10, 12, 15]
OK_REASONS = {"EventLoopCompleted", "EarlyDrop", "TerminationRequested"}
mt, ct = float(args[-2]), float(args[-1])
MIB = 1_048_576

survey = {}
for i, mp in enumerate(MP):
    survey[mp] = (args[i*5], args[i*5+1], args[i*5+2], args[i*5+3], args[i*5+4])

print("\nSurvey Results:")
print(f"{'MP':>4}  {'Func':>5}  {'Telem':>5}  {'CPU ms':>8}  {'Mem MiB':>8}  {'Reason':>22}  {'Viable':>7}")
print("-" * 75)

viable = []
for mp in MP:
    fp, tok, cpu_r, mem_r, reason = survey[mp]
    if fp != "true" or tok != "true":
        print(f"{mp:>4}  {fp:>5}  {tok:>5}  {'—':>8}  {'—':>8}  {reason or '—':>22}  {'NO':>7}")
        continue
    try:
        cpu = float(cpu_r); mem = float(mem_r)
    except (ValueError, TypeError):
        print(f"{mp:>4}  {fp:>5}  {tok:>5}  {'ERR':>8}  {'ERR':>8}  {reason:>22}  {'NO':>7}")
        continue
    mib = mem / MIB
    ok = (reason in OK_REASONS and cpu <= ct and mib <= mt)
    if ok:
        viable.append(mp)
    print(f"{mp:>4}  {fp:>5}  {tok:>5}  {cpu:>8.0f}  {mib:>8.1f}  {reason:>22}  {'YES' if ok else 'NO':>7}")
print("-" * 75)

if viable:
    rec = max(viable)
    print(f"\nRECOMMENDED_CEILING={rec}")
    print(f"VIABLE_LEVELS={' '.join(str(m) for m in viable)}")
else:
    print("\nRECOMMENDED_CEILING=NONE")
    print("VIABLE_LEVELS=")
PYEOF
)

echo "$ceiling_output"
results_append "$ceiling_output"

RECOMMENDED_CEILING=$(echo "$ceiling_output" | grep '^RECOMMENDED_CEILING=' \
  | cut -d= -f2 | tr -d '[:space:]')
VIABLE_LEVELS_STR=$(echo "$ceiling_output" | grep '^VIABLE_LEVELS=' \
  | cut -d= -f2 | tr -d '[:space:]')

if [[ "$RECOMMENDED_CEILING" == "NONE" || -z "$RECOMMENDED_CEILING" ]]; then
  fail "No viable ceiling found"
  results_append "CEILING SELECTION: FAIL — no viable ceiling"
  exit 1
fi

echo ""
echo "Recommended ceiling: ${RECOMMENDED_CEILING} MP  Viable: ${VIABLE_LEVELS_STR}"
read -rp "Enter ceiling MP (press Enter for ${RECOMMENDED_CEILING}): " operator_ceiling
operator_ceiling="${operator_ceiling:-$RECOMMENDED_CEILING}"

[[ "$operator_ceiling" =~ ^[0-9]+$ ]] \
  || { echo "FATAL: ceiling must be a number; got '$operator_ceiling'" >&2; exit 1; }

viable_ok=false
for vl in $VIABLE_LEVELS_STR; do
  [[ "$vl" == "$operator_ceiling" ]] && viable_ok=true
done
[[ "$viable_ok" == "true" ]] \
  || { echo "FATAL: $operator_ceiling not in VIABLE_LEVELS — requires new three-party decision" >&2; exit 1; }
[[ "$operator_ceiling" -le "$RECOMMENDED_CEILING" ]] \
  || { echo "FATAL: $operator_ceiling > recommended — requires new three-party decision" >&2; exit 1; }

CHOSEN_MP="$operator_ceiling"
read -r CHOSEN_W CHOSEN_H CHOSEN_PX <<< "${SURVEY_DIMS[$CHOSEN_MP]}"
read -r CHOSEN_MIN_B CHOSEN_MAX_B <<< "${SURVEY_BANDS[$CHOSEN_MP]}"
REJECT_W=$((CHOSEN_W + 1)); REJECT_PX=$((REJECT_W * CHOSEN_H))
results_append "Confirmed ceiling: ${CHOSEN_MP} MP (${CHOSEN_W}x${CHOSEN_H}, ${CHOSEN_PX} px)"

# ===========================================================================
# GENERATE + VERIFY CONFIRMATION FIXTURES
# ===========================================================================
python3 "$FIXTURES_PY" "$IMG_DIR" confirm \
  "$CHOSEN_W" "$CHOSEN_H" "$CHOSEN_PX" "$CHOSEN_MIN_B" "$CHOSEN_MAX_B" \
  || { echo "FATAL: confirmation fixture gen failed" >&2; exit 1; }

results_append ""; results_append "## Confirmation Fixture Preflight"
conf_ok=true

for i in 1 2 3; do
  cj="$IMG_DIR/test-C-jpeg-${i}.jpg"
  [[ -f "$cj" ]] || { echo "FATAL: $cj missing" >&2; exit 1; }
  sz=$(wc -c < "$cj" | awk '{print $1}')
  dm=$(python3 -c "
from PIL import Image
with Image.open('$cj') as im: print(im.width, im.height)
" 2>/dev/null)
  cw=$(echo "$dm"|awk '{print $1}'); ch=$(echo "$dm"|awk '{print $2}')
  ok=true
  [[ "$cw" == "$CHOSEN_W" && "$ch" == "$CHOSEN_H" ]] \
    || { fail "PREFLIGHT C-JPEG-$i: ${cw}x${ch} ≠ ${CHOSEN_W}x${CHOSEN_H}"; ok=false; }
  python3 -c "import sys; sys.exit(0 if $CHOSEN_MIN_B <= $sz <= $CHOSEN_MAX_B else 1)" \
    || { fail "PREFLIGHT C-JPEG-$i: size $sz outside [$CHOSEN_MIN_B,$CHOSEN_MAX_B]"; ok=false; }
  [[ "$sz" -le 10000000 ]] \
    || { fail "PREFLIGHT C-JPEG-$i: $sz > 10 MB"; ok=false; }
  python3 "$VERIFY_IN_PY" jpeg "$cj" \
    || { fail "PREFLIGHT C-JPEG-$i: metadata families missing"; ok=false; }
  [[ "$ok" == "true" ]] || conf_ok=false
  results_append "C-JPEG-$i: ${sz}B ${cw}x${ch}"
  echo "PREFLIGHT C-JPEG-$i: ${sz}B $([[ "$ok" == "true" ]] && echo ✓ || echo FAIL)"
done

cwebp="$IMG_DIR/test-C-webp.webp"
[[ -f "$cwebp" ]] || { echo "FATAL: $cwebp missing" >&2; exit 1; }
wsz=$(wc -c < "$cwebp" | awk '{print $1}')
wdm=$(python3 -c "
from PIL import Image
with Image.open('$cwebp') as im: print(im.width, im.height)
" 2>/dev/null)
ww=$(echo "$wdm"|awk '{print $1}'); wh=$(echo "$wdm"|awk '{print $2}')
[[ "$ww" == "$CHOSEN_W" && "$wh" == "$CHOSEN_H" ]] \
  || { fail "PREFLIGHT C-WEBP: ${ww}x${wh} ≠ ${CHOSEN_W}x${CHOSEN_H}"; conf_ok=false; }
[[ "$wsz" -le 10000000 ]] \
  || { fail "PREFLIGHT C-WEBP: $wsz > 10 MB"; conf_ok=false; }
python3 "$VERIFY_IN_PY" webp "$cwebp" \
  || { fail "PREFLIGHT C-WEBP: metadata families missing"; conf_ok=false; }
results_append "C-WEBP: ${wsz}B ${ww}x${wh}"; echo "PREFLIGHT C-WEBP: ${wsz}B ✓"

creject="$IMG_DIR/test-C-reject.jpg"
[[ -f "$creject" ]] || { echo "FATAL: $creject missing" >&2; exit 1; }
rdm=$(python3 -c "
from PIL import Image
with Image.open('$creject') as im: print(im.width, im.height)
" 2>/dev/null)
rw=$(echo "$rdm"|awk '{print $1}'); rh=$(echo "$rdm"|awk '{print $2}')
rsz=$(wc -c < "$creject" | awk '{print $1}')
[[ "$rw" == "$REJECT_W" && "$rh" == "$CHOSEN_H" ]] \
  || { fail "PREFLIGHT C-REJECT: ${rw}x${rh} ≠ ${REJECT_W}x${CHOSEN_H}"; conf_ok=false; }
[[ "$rsz" -le 500000 ]] \
  || { fail "PREFLIGHT C-REJECT: ${rsz}B > 500,000B ceiling"; conf_ok=false; }
results_append "C-REJECT: ${rw}x${rh} ${rsz}B"; echo "PREFLIGHT C-REJECT: ${rw}x${rh} ${rsz}B ✓"

[[ "$conf_ok" == "true" ]] \
  || { echo "FATAL: confirmation fixture preflight failed" >&2; exit 1; }

# ===========================================================================
# MID-RUN CEILING APPROVAL GATE
# ===========================================================================
update_pixel_limit "$CHOSEN_PX"
CONFIRM_HASH=$(shasum -a 256 "$SPIKE_DIR/index.ts" | awk '{print $1}')
results_append ""; results_append "## Confirmation Function"
results_append "CANONICAL_PIXEL_LIMIT: $CHOSEN_PX"
results_append "index.ts (confirmation) sha256: $CONFIRM_HASH"

echo ""
echo "=== MID-RUN CONFIRMATION FUNCTION APPROVAL ==="
echo "CANONICAL_PIXEL_LIMIT: $CHOSEN_PX  index.ts sha256: $CONFIRM_HASH"
read -rp "Type YES to confirm three-party approval: " _cc
[[ "$_cc" == "YES" ]] || { echo "Confirmation aborted." >&2; exit 1; }
results_append "Mid-run approval: YES"

# ===========================================================================
# CONFIRMATION PHASES C-1, C-2, C-3
# ===========================================================================
results_append ""; results_append "## Confirmation Phases — JPEG"

for i in 1 2 3; do
  clabel="C-${i}"; cfile="test-C-jpeg-${i}.jpg"; seed=$((41+i))
  results_append ""; results_append "### Phase $clabel (seed=${seed})"
  echo ""; echo "=== CONFIRMATION PHASE $clabel ==="

  deploy_function "$clabel" || exit 1

  invoke_case "$clabel" "$cfile" "image/jpeg" "true" "" \
    "$CHOSEN_W" "$CHOSEN_H" "$CHOSEN_PX"
  inv_exit=$?
  if [[ $inv_exit -eq 2 ]]; then
    fail "$clabel: HTTP 546 — ceiling selection invalid; gate FAIL"
    delete_confirmed "$clabel" || true; exit 1
  fi
  phase_wall="$LAST_WALL_TIME"; phase_run_id="$LAST_RUN_ID"
  python3 -c "import sys; sys.exit(0 if float('$phase_wall') <= 30 else 1)" \
    || fail "$clabel: cold wall-clock ${phase_wall}s > 30 s"
  results_append "$clabel cold_wall_time_s: $phase_wall"

  delete_confirmed "$clabel" || exit 1

  telemetry_gate "$clabel" "$phase_run_id"
  confirmation_telemetry_result "$clabel" \
    || fail "$clabel: confirmation telemetry gate failed"
done

# ===========================================================================
# CONFIRMATION PHASE C-4 — WebP (cold) + Rejection (warm)
# ===========================================================================
results_append ""; results_append "## Confirmation Phase C-4 (WebP + Rejection)"
echo ""; echo "=== CONFIRMATION PHASE C-4 ==="

deploy_function "C-4" || exit 1

invoke_case "C-WEBP" "test-C-webp.webp" "image/webp" "true" "" \
  "$CHOSEN_W" "$CHOSEN_H" "$CHOSEN_PX"
if [[ $? -eq 2 ]]; then
  fail "C-WEBP: HTTP 546 — ceiling selection invalid"
  delete_confirmed "C-4" || true; exit 1
fi
webp_run_id="$LAST_RUN_ID"; webp_wall="$LAST_WALL_TIME"
python3 -c "import sys; sys.exit(0 if float('$webp_wall') <= 30 else 1)" \
  || fail "C-WEBP: cold wall-clock ${webp_wall}s > 30 s"
results_append "C-WEBP cold_wall_time_s: $webp_wall"

# C-REJECT: capture return code; 546 = hard confirmation failure; exit immediately
invoke_case "C-REJECT" "test-C-reject.jpg" "image/jpeg" "false" "pre_decode_rejected" \
  "$REJECT_W" "$CHOSEN_H" "$REJECT_PX"
reject_exit=$?
if [[ $reject_exit -eq 2 ]]; then
  fail "C-REJECT: HTTP 546 — confirmation failure"
  delete_confirmed "C-4" || true; exit 1
fi
results_append "C-REJECT wall_time_s: $LAST_WALL_TIME"

delete_confirmed "C-4" || exit 1

telemetry_gate "C-WEBP" "$webp_run_id"
confirmation_telemetry_result "C-WEBP" \
  || fail "C-WEBP: confirmation telemetry gate failed"

# ===========================================================================
# FINAL VERDICT
# ===========================================================================
echo ""; echo "================================================================="
results_append ""; results_append "## Final Verdict"
results_append "Chosen ceiling: ${CHOSEN_MP} MP (${CHOSEN_W}x${CHOSEN_H}, ${CHOSEN_PX} px)"

if [[ "$GATE2B_PASS" == "true" ]]; then
  echo "Gate 2B Rev 14: PASS"
  echo "CANONICAL_PIXEL_LIMIT: $CHOSEN_PX (${CHOSEN_MP} MP, ${CHOSEN_W}x${CHOSEN_H})"
  results_append "Verdict: PASS"
  results_append "CANONICAL_PIXEL_LIMIT: $CHOSEN_PX (${CHOSEN_MP} MP)"
else
  echo "Gate 2B Rev 14: FAIL"
  results_append "Verdict: FAIL"
  results_append "Failures:"
  for r in "${FAIL_REASONS[@]}"; do
    echo "  - $r"; results_append "  - $r"; done
fi
echo "Results: $RESULTS_MD"
echo "================================================================="
[[ "$GATE2B_PASS" == "true" ]] || exit 1
```

---

## Section 12 — Pre-Deployment Checklist Summary

1. `python3 gate2b-fixtures-r14.py test-images-r14/` — survey fixtures
2. `bash gate2b-local-test-r14.sh` — S-5 (`image_decode_started: true`), reject (`false`)
3. `deno fmt --check`, `deno lint`, `deno check` — zero findings
4. `bash -n tools/image-spike/gate2b-run-r14.sh` — exit 0
5. `python3 -m py_compile` for all three Python scripts — exit 0
6. `gitleaks detect` — no findings
7. `shasum -a 256 magick.wasm index.ts` — record both hashes
8. Confirm `CANONICAL_PIXEL_LIMIT = 15_500_000` in index.ts
9. Submit all artifacts; receive three-party sign-off

---

## Section 13 — Results Format

```
gate2b-evidence-r14-<TIMESTAMP>/
  gate2b-results.md
  responses/
    S-5.json S-5.headers S-5_output.webp
    S-8.json  ...
    S-10.json ...
    S-12.json ...
    S-15.json ...
    C-1.json C-1.headers C-1_output.webp
    C-2.json C-2.headers C-2_output.webp
    C-3.json C-3.headers C-3_output.webp
    C-WEBP.json C-WEBP.headers C-WEBP_output.webp
    C-REJECT.json C-REJECT.headers
```

---

## Section 14 — iOS / Swift Client Requirement

`CANONICAL_PIXEL_LIMIT` established by Rev 14 is the mandatory upload pixel ceiling.

1. Swift client MUST check `width × height` before any upload.
2. If `width × height > CANONICAL_PIXEL_LIMIT`, client MUST downscale and re-encode before upload. Hard requirement.
3. Server rejects oversized images pre-decode with `accepted: false, reason: pre_decode_rejected, image_decode_started: false`.
4. Client-side downscaling does not replace server-side sanitization.

---

## Approval Request

All 4 Codex findings from Rev 13 are addressed. No cloud operation has been performed.

Requested action: three-party sign-off (Bill + Claude + Codex) using the magic words:

**`APPROVED: Gate 2B Rev 14 — Pixel Ceiling Discovery Spike`**
