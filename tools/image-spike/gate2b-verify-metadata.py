#!/usr/bin/env python3
"""
Byte-level WebP RIFF chunk parser — Gate 2B metadata verification.
Strict: requires file length == 8 + declared RIFF payload.
         requires parsing to end exactly at RIFF boundary.
Exit 0: clean. Exit 1: metadata found. Exit 2: invalid/malformed.
"""
import sys
import struct

METADATA_FOURCCS: dict[bytes, str] = {
    b'EXIF': 'EXIF (contains EXIF IFD, GPS IFD, IPTC-NAA embedded in EXIF)',
    b'ICCP': 'ICCP (ICC color profile)',
    b'XMP ': 'XMP  (XMP metadata; may contain IPTC-IIM, dc:description)',
}
MAX_CHUNKS = 1024


def parse_webp_riff(data: bytes) -> list[str]:
    if len(data) < 12:
        raise ValueError(f"File too short ({len(data)} bytes; need ≥12 for RIFF/WEBP header)")

    if data[0:4] != b'RIFF':
        raise ValueError(f"Not RIFF: leading bytes are {data[0:4]!r}")

    declared_payload = struct.unpack_from('<I', data, 4)[0]
    expected_len = 8 + declared_payload

    # Strict: actual file length must equal declared RIFF length
    if len(data) != expected_len:
        raise ValueError(
            f"File length {len(data)} ≠ declared RIFF size "
            f"(header declares {declared_payload} payload bytes → expected file {expected_len} bytes)"
        )

    if data[8:12] != b'WEBP':
        raise ValueError(f"RIFF type is not WEBP: got {data[8:12]!r}")

    found: list[str] = []
    riff_end = expected_len  # == len(data)
    pos = 12
    chunk_count = 0

    while pos + 8 <= riff_end:
        chunk_count += 1
        if chunk_count > MAX_CHUNKS:
            raise ValueError(f"Exceeded {MAX_CHUNKS} chunks at pos={pos} — malformed input")

        fourcc = data[pos:pos + 4]
        chunk_data_size = struct.unpack_from('<I', data, pos + 4)[0]
        chunk_data_end = pos + 8 + chunk_data_size

        # Validate chunk boundary against RIFF boundary
        if chunk_data_end > riff_end:
            raise ValueError(
                f"Chunk at pos={pos} ({fourcc!r}) declares {chunk_data_size} bytes "
                f"(end={chunk_data_end}) exceeds RIFF boundary ({riff_end})"
            )

        if fourcc in METADATA_FOURCCS:
            found.append(
                f"  pos={pos}  fourcc={fourcc.decode('ascii','replace')!r}"
                f"  size={chunk_data_size}  — {METADATA_FOURCCS[fourcc]}"
            )

        pad = chunk_data_size % 2
        pos = chunk_data_end + pad

    # Strict: parsing must end exactly at RIFF boundary
    if pos != riff_end:
        raise ValueError(
            f"Parsing ended at pos={pos} but RIFF boundary is {riff_end} "
            f"({riff_end - pos} trailing bytes before boundary)"
        )

    return found


def main() -> None:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <file.webp>", file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]
    try:
        with open(path, 'rb') as f:
            data = f.read()
    except OSError as e:
        print(f"ERROR reading {path}: {e}", file=sys.stderr)
        sys.exit(2)
    try:
        found = parse_webp_riff(data)
    except ValueError as e:
        print(f"INVALID WebP — {e}", file=sys.stderr)
        sys.exit(2)
    if found:
        print(f"METADATA FOUND in {path} — Gate 2B FAIL:")
        for entry in found:
            print(entry)
        sys.exit(1)
    print(f"OK: {path} — no EXIF/ICCP/XMP chunks ({len(data)} bytes)")
    sys.exit(0)


if __name__ == '__main__':
    main()
