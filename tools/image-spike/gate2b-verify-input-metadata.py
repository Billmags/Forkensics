#!/usr/bin/env python3
"""gate2b-verify-input-metadata.py — structural metadata verification (Rev 14).
Usage:
  python3 gate2b-verify-input-metadata.py jpeg <path>
  python3 gate2b-verify-input-metadata.py webp <path>
Exit 0 if all required families present; exit 1 otherwise.
"""
import sys, os, struct

# ---------------------------------------------------------------------------
# JPEG marker parser — traverses FF XX [len_hi][len_lo][data] segments
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
        mtype  = data[pos]; pos += 1
        marker = bytes([0xff, mtype])
        if marker in _STANDALONE:
            continue
        if mtype == 0xda:   # SOS — no more metadata markers
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
# RIFF/WebP chunk parser — exact size required (no trailing bytes accepted)
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
    """Verify APP13 contains Photoshop 3.0 / 8BIM resource ID 0x0404 (IPTC-NAA)."""
    PS_HDR = b"Photoshop 3.0\x00"
    for seg in markers.get(b"\xff\xed", []):
        if not seg.startswith(PS_HDR):
            continue
        p = len(PS_HDR)
        while p + 12 <= len(seg):
            if seg[p:p+4] != b"8BIM":
                break
            res_id   = struct.unpack(">H", seg[p+4:p+6])[0]
            name_len = seg[p+6] if p + 6 < len(seg) else 0
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
    """Parse the EXIF chunk with piexif to confirm a GPS IFD is present."""
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
        print(f"FAIL {os.path.basename(path)}: {e}")
        return False
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
        print(f"FAIL {os.path.basename(path)}: {e}")
        return False
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
    print(f"OK   {os.path.basename(path)}: EXIF+GPS, ICC, XMP chunks present")
    return True


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    fmt, path = sys.argv[1], sys.argv[2]
    if not os.path.exists(path):
        print(f"FAIL: {path} not found")
        sys.exit(1)
    ok = verify_jpeg(path) if fmt == "jpeg" else verify_webp(path)
    sys.exit(0 if ok else 1)
