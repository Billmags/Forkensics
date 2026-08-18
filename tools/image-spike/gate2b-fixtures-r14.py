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
    # (id, w, h, pixels, min_b, max_b, q_start)
    ("S-5",  2500, 2000,  5_000_000,  4_000_000,  5_500_000, 91),
    ("S-8",  4000, 2000,  8_000_000,  6_500_000,  9_000_000, 90),
    ("S-10", 4000, 2500, 10_000_000,  8_500_000, 10_000_000, 92),
    ("S-12", 4000, 3000, 12_000_000,  9_000_000, 10_000_000, 85),
    ("S-15", 5000, 3000, 15_000_000,  9_000_000, 10_000_000, 79),
]
UPLOAD_CEIL      = 10_000_000
REJECT_MAX_BYTES = 500_000

# ---------------------------------------------------------------------------
# Metadata builders
# ---------------------------------------------------------------------------
def _icc_profile() -> bytes:
    """Real Pillow-generated sRGB ICC profile via ImageCmsProfile.tobytes()."""
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
            piexif.GPSIFD.GPSLatitude:     ((37, 1), (46, 1), (30, 1)),
            piexif.GPSIFD.GPSLongitudeRef: b"W",
            piexif.GPSIFD.GPSLongitude:    ((122, 1), (25, 1), (0, 1)),
        },
        "1st": {}, "thumbnail": None,
    }
    return piexif.dump(exif)

def _xmp_bytes() -> bytes:
    return (
        b'<?xpacket begin="\xef\xbb\xbf" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
        b'<x:xmpmeta xmlns:x="adobe:ns:meta/">'
        b'<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"/>'
        b'</x:xmpmeta>'
        b'<?xpacket end="w"?>'
    )

def _iptc_app13() -> bytes:
    """APP13 with Photoshop 3.0 / 8BIM / IPTC-NAA (resource ID 0x0404)."""
    caption   = b"Gate2B-Rev14-IPTC-Test"
    byline    = b"ForkensicsSpike"
    ds120     = b"\x1c\x02\x78" + struct.pack(">H", len(caption)) + caption
    ds080     = b"\x1c\x02\x50" + struct.pack(">H", len(byline)) + byline
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
            f"but actual length is {len(data)}B"
        )
    pos = 12
    out: dict = {}
    while pos + 8 <= len(data):
        tag  = data[pos:pos+4]
        size = struct.unpack("<I", data[pos+4:pos+8])[0]
        if pos + 8 + size > len(data):
            raise ValueError(
                f"Chunk {tag!r} at offset {pos} claims {size}B but only "
                f"{len(data)-pos-8} remain"
            )
        out.setdefault(tag, []).append(data[pos+8:pos+8+size])
        pos += 8 + size + (size & 1)
    return out

# ---------------------------------------------------------------------------
# Image builders
# ---------------------------------------------------------------------------
def _noise_image(w: int, h: int, seed: int = 42) -> Image.Image:
    rng = np.random.default_rng(seed=seed)
    return Image.fromarray(
        rng.integers(0, 256, (h, w, 3), dtype=np.uint8), "RGB"
    )

def _write_jpeg_full(img: Image.Image, quality: int, path: str) -> int:
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality,
             exif=_exif_bytes(), icc_profile=_icc_profile())
    raw = buf.getvalue()
    raw = _inject_app1_xmp(raw)
    raw = _inject_comment(raw)
    raw = raw[:2] + _iptc_app13() + raw[2:]
    with open(path, "wb") as f:
        f.write(raw)
    return len(raw)

def _write_webp_full(img: Image.Image, quality: int, path: str) -> int:
    """Save WebP using Pillow native xmp parameter; validate RIFF chunks."""
    buf = io.BytesIO()
    img.save(buf, "WEBP", quality=quality,
             exif=_exif_bytes(), icc_profile=_icc_profile(), xmp=_xmp_bytes())
    raw = buf.getvalue()
    chunks = _parse_riff_chunks(raw)
    missing = [t.decode() for t in (b"EXIF", b"ICCP", b"XMP ") if t not in chunks]
    if missing:
        raise RuntimeError(
            f"WebP missing chunks after save: {missing}. "
            "Requires Pillow >= 9.3.0 with WebP xmp support."
        )
    with open(path, "wb") as f:
        f.write(raw)
    return len(raw)

# ---------------------------------------------------------------------------
# Survey fixture generation
# ---------------------------------------------------------------------------
def generate_survey(out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    print("Gate 2B Rev 14 — survey fixture generation ...")
    for sid, w, h, _px, lo, hi, q_start in SURVEY:
        path = os.path.join(out_dir, f"test-{sid}.jpg")
        img  = _noise_image(w, h, seed=42)
        size = -1
        for q in range(q_start, 49, -1):
            size = _write_jpeg_full(img, q, path)
            if lo <= size <= hi and size <= UPLOAD_CEIL:
                break
        if size < 0 or not (lo <= size <= hi) or size > UPLOAD_CEIL:
            print(
                f"FATAL: {sid} cannot meet band [{lo},{hi}] ≤ {UPLOAD_CEIL}",
                file=sys.stderr,
            )
            sys.exit(1)
        sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
        print(f"{sid} ({w}x{h}) q={q} size={size:,}B sha={sha[:16]}... ✓")
    print("=== Survey fixtures generated ===")

# ---------------------------------------------------------------------------
# Confirmation fixture generation
# ---------------------------------------------------------------------------
def generate_confirmation(
    out_dir: str, cw: int, ch: int, cp: int, min_b: int, max_b: int
) -> None:
    os.makedirs(out_dir, exist_ok=True)

    # C-JPEG-1, C-JPEG-2, C-JPEG-3 — finite downward sweep; no oscillation
    for i, seed in enumerate([42, 43, 44], start=1):
        path = os.path.join(out_dir, f"test-C-jpeg-{i}.jpg")
        img  = _noise_image(cw, ch, seed=seed)
        candidates = []
        for q in range(95, 49, -1):
            size = _write_jpeg_full(img, q, path)
            if min_b <= size <= max_b and size <= UPLOAD_CEIL:
                candidates.append((q, size))
        if not candidates:
            print(
                f"FATAL: C-JPEG-{i} (seed={seed}) cannot meet band "
                f"[{min_b},{max_b}] at any quality in 50..95",
                file=sys.stderr,
            )
            sys.exit(1)
        best_q, best_size = candidates[0]
        _write_jpeg_full(img, best_q, path)
        sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
        print(
            f"C-JPEG-{i} (seed={seed}): q={best_q} {cw}x{ch} "
            f"{best_size:,}B sha={sha[:16]}... ✓"
        )

    # C-WEBP
    webp_path = os.path.join(out_dir, "test-C-webp.webp")
    img42     = _noise_image(cw, ch, seed=42)
    size_w    = -1
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
    Image.new("RGB", (cw + 1, ch), (30, 60, 90)).save(reject_path, "JPEG", quality=1)
    size_r = os.path.getsize(reject_path)
    if size_r > REJECT_MAX_BYTES:
        print(
            f"FATAL: C-REJECT {size_r}B > {REJECT_MAX_BYTES}B ceiling",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"C-REJECT: {cw+1}x{ch}={(cw+1)*ch:,}px {size_r:,}B ≤{REJECT_MAX_BYTES} ✓")
    print("=== Confirmation fixtures generated ===")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    out = sys.argv[1]
    if len(sys.argv) == 8 and sys.argv[2] == "confirm":
        generate_confirmation(
            out,
            int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]),
            int(sys.argv[6]), int(sys.argv[7]),
        )
    else:
        generate_survey(out)
