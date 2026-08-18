#!/usr/bin/env python3
"""
gate2b-fixtures.py — Gate 2B fixture generator
Generates 7 deterministic test images with full metadata families.
Usage: python3 gate2b-fixtures.py <output_dir>
"""

import sys
import os
import struct
import hashlib
import io
import math

try:
    from PIL import Image
    import numpy as np
    import piexif
except ImportError as e:
    print(f"Missing dependency: {e}")
    print("Run: pip3 install Pillow numpy piexif --break-system-packages")
    sys.exit(1)

# ── Manifest ──────────────────────────────────────────────────────────────────
# (label, width, height, min_bytes, max_bytes, format, noise, has_meta)
MANIFEST = [
    ("B-01", 2500, 2000,  4_500_000,  5_500_000, "jpeg", True,  True),
    ("B-02", 4000, 2500,  8_500_000, 10_000_000, "jpeg", True,  True),
    ("B-03", 5000, 4000,  8_500_000, 10_000_000, "jpeg", True,  True),
    ("B-04", 5001, 4000,     10_000,    500_000,  "jpeg", False, False),
    ("B-05",10000,10000,  1_000_000,  2_500_000,  "jpeg", False, False),
    ("B-06", 2500, 2000,  4_500_000,  5_500_000, "webp", True,  True),
    ("B-07", 6000, 4000,     10_000,    500_000,  "jpeg", False, False),
]

FIXTURE_COLORS = {
    "B-04": (30, 60, 90),
    "B-05": (60, 90, 30),
    "B-07": (90, 30, 60),
}

# ── Helpers ───────────────────────────────────────────────────────────────────

def _noise_image(width: int, height: int, seed: int = 42) -> np.ndarray:
    """Create a fresh RNG on every call — each fixture is independently seeded."""
    rng = np.random.default_rng(seed)
    return rng.integers(0, 256, (height, width, 3), dtype=np.uint8)


def _arr_to_image(arr: np.ndarray) -> Image.Image:
    """Convert numpy array to PIL Image without deprecated mode parameter."""
    return Image.fromarray(arr)


def _solid_image(width: int, height: int, color: tuple) -> np.ndarray:
    arr = np.full((height, width, 3), color, dtype=np.uint8)
    return arr


def _make_com(text: bytes) -> bytes:
    """Build a valid JPEG COM segment."""
    length = 2 + len(text)
    return b'\xff\xfe' + struct.pack('>H', length) + text


def _build_exif() -> bytes:
    """Build minimal EXIF with GPS sub-IFD."""
    gps_ifd = {
        piexif.GPSIFD.GPSLatitudeRef: b'N',
        piexif.GPSIFD.GPSLatitude: ((37, 1), (46, 1), (0, 1)),
        piexif.GPSIFD.GPSLongitudeRef: b'W',
        piexif.GPSIFD.GPSLongitude: ((122, 1), (25, 1), (0, 1)),
    }
    exif_ifd = {
        piexif.ExifIFD.UserComment: b"Gate2B fixture",
    }
    zeroth_ifd = {
        piexif.ImageIFD.Make: b"Gate2B",
        piexif.ImageIFD.Model: b"fixture-generator",
        piexif.ImageIFD.Software: b"gate2b-fixtures.py",
    }
    return piexif.dump({"0th": zeroth_ifd, "Exif": exif_ifd, "GPS": gps_ifd})


def _build_xmp() -> bytes:
    return b"""<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?>
<x:xmpmeta xmlns:x='adobe:ns:meta/'>
  <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
    <rdf:Description rdf:about='' xmlns:dc='http://purl.org/dc/elements/1.1/'>
      <dc:description>Gate 2B fixture image</dc:description>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
<?xpacket end='w'?>"""


def _build_icc() -> bytes:
    """Minimal sRGB-like ICC profile (just enough bytes for Pillow to attach)."""
    return (
        b'\x00\x00\x00\x0csRGB'
        b'acsp'
        + b'\x00' * 20
        + b'RGB '
        + b'\x00' * 40
    )


def _build_iptc() -> bytes:
    """Minimal IPTC/NAA record."""
    # Record 2, Dataset 116 (copyright notice)
    data = b'Gate2B fixture'
    tag = struct.pack('>BBH', 2, 116, len(data)) + data
    return b'\x1c' + tag


def find_quality_for_band(encode_fn, min_bytes, max_bytes, label):
    """Find JPEG quality in [1,95] that puts output in [min_bytes, max_bytes]."""
    q = 95
    while q > 1:
        data = encode_fn(q)
        size = len(data)
        if size <= max_bytes:
            break
        q = max(1, q - 5)
    data = encode_fn(q)
    size = len(data)
    if size >= min_bytes:
        # Fine-step up
        for tq in range(q + 1, min(q + 6, 96)):
            td = encode_fn(tq)
            ts = len(td)
            if ts <= max_bytes:
                q, size = tq, ts
            else:
                break
        return q, size
    # Try to climb into band
    for dq in range(1, 6):
        tq = q + dq
        if tq > 95:
            break
        td = encode_fn(tq)
        ts = len(td)
        if min_bytes <= ts <= max_bytes:
            return tq, ts
        if ts > max_bytes:
            break
    raise RuntimeError(
        f"{label}: no quality in [1,95] produces size in [{min_bytes:,}, {max_bytes:,}]"
    )


def encode_jpeg_with_meta(arr: np.ndarray, quality: int) -> bytes:
    """Encode numpy array to JPEG bytes with full metadata families."""
    img = _arr_to_image(arr)
    exif_bytes = _build_exif()
    xmp_bytes = _build_xmp()
    icc_bytes = _build_icc()
    iptc_bytes = _build_iptc()
    comment = b'Gate2B JFIF comment marker v6'

    buf = io.BytesIO()
    img.save(buf, format='JPEG', quality=quality,
             exif=exif_bytes, icc_profile=icc_bytes)
    raw = buf.getvalue()

    # Insert COM marker just after the SOI (FF D8)
    com_segment = _make_com(comment)
    raw_with_com = raw[:2] + com_segment + raw[2:]

    # Inject IPTC into APP13 (Photoshop 3.0)
    iptc_block = b'Photoshop 3.0\x00' + b'\x38\x42\x49\x4d' + struct.pack('>H', 0x0404)
    iptc_len = struct.pack('>H', len(iptc_bytes))
    app13_data = iptc_block + iptc_len + iptc_bytes
    app13_segment = b'\xff\xed' + struct.pack('>H', 2 + len(app13_data)) + app13_data
    raw_with_com = raw_with_com[:2] + app13_segment + raw_with_com[2:]

    # Inject XMP into APP1 (after EXIF APP1 if present)
    xmp_ns = b'http://ns.adobe.com/xap/1.0/\x00'
    xmp_payload = xmp_ns + xmp_bytes
    app1_xmp = b'\xff\xe1' + struct.pack('>H', 2 + len(xmp_payload)) + xmp_payload
    # Insert after the first APP1 (EXIF) if present, else after SOI
    insert_at = 2
    if raw_with_com[2:4] == b'\xff\xe1':
        seg_len = struct.unpack('>H', raw_with_com[4:6])[0]
        insert_at = 2 + 2 + seg_len
    raw_with_com = raw_with_com[:insert_at] + app1_xmp + raw_with_com[insert_at:]

    return raw_with_com


def encode_webp_with_meta(arr: np.ndarray, quality: int) -> bytes:
    """Encode numpy array to WebP bytes with full metadata families."""
    img = _arr_to_image(arr)
    exif_bytes = _build_exif()
    xmp_bytes = _build_xmp()
    icc_bytes = _build_icc()
    buf = io.BytesIO()
    img.save(buf, format='WEBP', quality=quality,
             exif=exif_bytes, icc_profile=icc_bytes)
    raw = buf.getvalue()
    # XMP embedding in WebP via re-save with xmp parameter if supported
    try:
        buf2 = io.BytesIO()
        img.save(buf2, format='WEBP', quality=quality,
                 exif=exif_bytes, icc_profile=icc_bytes, xmp=xmp_bytes)
        raw = buf2.getvalue()
    except TypeError:
        pass  # older Pillow; XMP not embedded
    return raw


def verify_metadata_families(data: bytes, fmt: str) -> list:
    """Return list of metadata family names present in the encoded bytes."""
    families = []
    if fmt == 'jpeg':
        # Scan APP markers
        i = 2  # skip SOI
        while i + 3 < len(data):
            if data[i] != 0xff:
                break
            marker = data[i + 1]
            if marker == 0xd9:
                break
            seg_len = struct.unpack('>H', data[i + 2:i + 4])[0]
            seg_data = data[i + 2:i + 2 + seg_len]
            # COM marker
            if marker == 0xfe:
                families.append('COMMENT')
            # APP1: EXIF or XMP
            elif marker == 0xe1:
                # seg_data starts with the 2-byte length field; payload begins at seg_data[2:]
                # piexif.load() accepts bytes starting with b'Exif\x00\x00'
                payload = seg_data[2:]  # actual APP1 payload (skips the length field)
                if payload[:6] == b'Exif\x00\x00':
                    families.append('EXIF')
                    try:
                        exif = piexif.load(payload)
                        if exif.get('GPS') and len(exif['GPS']) > 0:
                            families.append('GPS')
                    except Exception:
                        pass
                elif b'http://ns.adobe.com/xap/1.0/' in payload:
                    families.append('XMP')
            # APP2: ICC
            elif marker == 0xe2:
                if seg_data[2:14] == b'ICC_PROFILE\x00':
                    families.append('ICC')
            # APP13: IPTC
            elif marker == 0xed:
                if b'Photoshop 3.0' in seg_data:
                    families.append('IPTC')
            i += 2 + seg_len
    elif fmt == 'webp':
        # RIFF chunk scan
        if data[0:4] == b'RIFF' and data[8:12] == b'WEBP':
            off = 12
            while off + 8 <= len(data):
                chunk_id = data[off:off+4]
                chunk_sz = struct.unpack('<I', data[off+4:off+8])[0]
                if chunk_id == b'EXIF':
                    families.append('EXIF')
                    families.append('GPS')  # EXIF in our fixtures always has GPS
                elif chunk_id == b'ICCP':
                    families.append('ICC')
                elif chunk_id == b'XMP ':
                    families.append('XMP')
                off += 8 + chunk_sz + (chunk_sz % 2)
                if chunk_sz == 0:
                    break
    return sorted(set(families))


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <output_dir>")
        sys.exit(1)

    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    print("Gate 2B fixture generation (deterministic, seed=42) ...")

    all_pass = True
    for (label, width, height, min_bytes, max_bytes, fmt, noise, has_meta) in MANIFEST:
        print(f"\n--- {label} ({width}x{height}, {fmt}) ---")
        filename = f"test-{label}.{'jpg' if fmt == 'jpeg' else 'webp'}"
        out_path = os.path.join(out_dir, filename)

        if noise:
            arr = _noise_image(width, height, seed=42)
        else:
            color = FIXTURE_COLORS[label]
            print(f"  color={color}", end="  ")
            arr = _solid_image(width, height, color)

        try:
            if fmt == 'jpeg':
                if noise:
                    def enc(q, a=arr, lbl=label):
                        return encode_jpeg_with_meta(a, q)
                    quality, size = find_quality_for_band(enc, min_bytes, max_bytes, label)
                    data = enc(quality)
                else:
                    quality = 1
                    buf = io.BytesIO()
                    _arr_to_image(arr).save(buf, format='JPEG', quality=quality)
                    data = buf.getvalue()
                    size = len(data)
            elif fmt == 'webp':
                def enc_w(q, a=arr):
                    return encode_webp_with_meta(a, q)
                quality, size = find_quality_for_band(enc_w, min_bytes, max_bytes, label)
                data = enc_w(quality)

        except RuntimeError as e:
            print(f"  ERROR: {e}")
            all_pass = False
            continue

        with open(out_path, 'wb') as f:
            f.write(data)

        sha = hashlib.sha256(data).hexdigest()
        size = len(data)
        mb = size / 1_000_000

        if has_meta:
            families = verify_metadata_families(data, fmt)
            # WebP RIFF only supports EXIF, ICCP (ICC), XMP chunks — no IPTC or COMMENT
            if fmt == 'webp':
                expected = {'EXIF', 'GPS', 'ICC', 'XMP'}
            else:
                expected = {'COMMENT', 'EXIF', 'GPS', 'ICC', 'IPTC', 'XMP'}
            missing = expected - set(families)
            meta_ok = not missing
            print(f"  metadata families: {sorted(families)} {'✓' if meta_ok else '✗ MISSING: ' + str(missing)}")
        else:
            meta_ok = True

        in_band = min_bytes <= size <= max_bytes
        if noise:
            print(f"  quality={quality}  size={size:,} bytes ({mb:.3f} MB)  sha256={sha[:32]}...")
        else:
            print(f"  quality={quality}  size={size:,} bytes ({mb:.3f} MB)  sha256={sha[:32]}...")
        verdict = "PASS ✓" if in_band and meta_ok else "FAIL ✗"
        print(f"  band=[{min_bytes:,},{max_bytes:,}]  {verdict}")
        if not (in_band and meta_ok):
            all_pass = False

    print(f"\n=== {'All fixtures generated' if all_pass else 'FIXTURE GENERATION FAILED'} ===")
    sys.exit(0 if all_pass else 1)


if __name__ == '__main__':
    main()
