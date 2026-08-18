#!/usr/bin/env bash
# parser/verify-webp.sh — forkensics-image-spike Rev 10
# Verifies WebP structural integrity per CF-P-6 spec.
#
# Usage: verify-webp.sh [--check-no-animation] <file.webp>
#
# Checks:
#   1. RIFF magic bytes 0-3 = 52 49 46 46 ("RIFF")
#   2. WEBP magic bytes 8-11 = 57 45 42 50 ("WEBP")
#   3. Exact file size: actual == riff_size_field + 8
#   4. First chunk is one of: VP8 (56503820), VP8L (5650384c), VP8X (56503858)
#   5. ALPH+VP8L combination forbidden — verified via RIFF chunk header walk
#      (ALPH fourcc 414c5048 in chunk headers, not in compressed data)
#   5a. For VP8X: exactly one VP8 or VP8L image bitstream chunk required (0 or 2+ rejected)
#   6. For VP8X: (flags & ~0x10) === 0 — only Alpha flag allowed in output
#      (0x01 = Reserved; 0x02 = Animation; 0x04 = XMP; 0x08 = Exif; 0x10 = Alpha; 0x20 = ICC)
#   7. If --check-no-animation: VP8X Animation flag (0x02) must be zero
#
# Returns 0 on PASS, 1 on FAIL.

set -euo pipefail

# ── Bash version guard ─────────────────────────────────────────────────────────
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || {
  echo "FAIL: Bash 4+ required (found ${BASH_VERSION:-unknown})"
  exit 1
}

# ── Dependency check ───────────────────────────────────────────────────────────
command -v dd >/dev/null || { echo "FAIL: dd required"; exit 1; }
{ command -v xxd >/dev/null || command -v od >/dev/null; } \
  || { echo "FAIL: xxd or od required for binary inspection"; exit 1; }

# ── Argument parsing ───────────────────────────────────────────────────────────
CHECK_NO_ANIM=false
FILE=""
for arg in "$@"; do
  case "$arg" in
    --check-no-animation) CHECK_NO_ANIM=true ;;
    -*) echo "FAIL: Unknown flag: $arg"; exit 1 ;;
    *) FILE="$arg" ;;
  esac
done

[ -n "$FILE" ] || { echo "FAIL: No file specified";        exit 1; }
[ -f "$FILE" ] || { echo "FAIL: File not found: $FILE";    exit 1; }
[ -r "$FILE" ] || { echo "FAIL: File not readable: $FILE"; exit 1; }

echo "Verifying: $FILE"

ACTUAL_SIZE=$(wc -c < "$FILE" | tr -d ' ')

# ── Helper: read N bytes at offset as lowercase hex string (no spaces) ─────────
# Uses xxd if available, falls back to od.
read_bytes_hex() {
  local offset="$1" count="$2"
  if command -v xxd >/dev/null 2>&1; then
    dd if="$FILE" bs=1 skip="$offset" count="$count" 2>/dev/null \
      | xxd -p | tr -d '\n'
  else
    od -A n -t x1 -j "$offset" -N "$count" "$FILE" 2>/dev/null \
      | tr -d ' \n'
  fi
}

# ── Helper: read 4-byte little-endian uint32 at offset → decimal ───────────────
read_le32() {
  local offset="$1"
  local hex
  hex=$(read_bytes_hex "$offset" 4)
  local b0="${hex:0:2}" b1="${hex:2:2}" b2="${hex:4:2}" b3="${hex:6:2}"
  printf '%d' "0x${b3}${b2}${b1}${b0}"
}

# ── Helper: walk RIFF chunk headers, print one fourcc hex per line ─────────────
# Reads chunk headers starting at offset 12 (past RIFF + 4-byte-size + WEBP).
# Only reads chunk FourCC and size fields — does NOT touch compressed data.
# Rejects any chunk whose payload extends beyond EOF.
# Requires the final padded offset to equal ACTUAL_SIZE (no trailing garbage).
walk_riff_chunks() {
  local offset=12
  local fourcc chunk_size next_offset
  while [ $(( offset + 8 )) -le "$ACTUAL_SIZE" ]; do
    fourcc=$(read_bytes_hex "$offset" 4)
    chunk_size=$(read_le32 $(( offset + 4 )))
    # Reject chunks whose data payload extends beyond EOF
    if [ $(( offset + 8 + chunk_size )) -gt "$ACTUAL_SIZE" ]; then
      printf 'FAIL: chunk %s at offset %d size %d extends beyond EOF (%d)\n' \
        "$fourcc" "$offset" "$chunk_size" "$ACTUAL_SIZE" >&2
      exit 1
    fi
    printf '%s\n' "$fourcc"
    next_offset=$(( offset + 8 + chunk_size ))
    # RIFF requires 2-byte alignment: if chunk_size is odd, skip 1 padding byte.
    # Use an explicit if-block — [ test ] && cmd returns 1 on false under set -e.
    if [ $(( chunk_size % 2 )) -ne 0 ]; then
      next_offset=$(( next_offset + 1 ))
    fi
    offset=$next_offset
  done
  # Require the final padded offset to equal ACTUAL_SIZE — no trailing bytes allowed.
  [ "$offset" -eq "$ACTUAL_SIZE" ] || {
    printf 'FAIL: RIFF chunk walk ended at offset %d, expected %d (trailing bytes or truncation)\n' \
      "$offset" "$ACTUAL_SIZE" >&2
    exit 1
  }
}

# ── Helper: check if a fourcc appears in the chunk list ───────────────────────
chunk_list_contains() {
  local needle="$1" hay
  while IFS= read -r hay; do
    [ "$hay" = "$needle" ] && return 0
  done
  return 1
}

# ── Check 1: RIFF magic ────────────────────────────────────────────────────────
RIFF_MAGIC=$(read_bytes_hex 0 4)
[ "$RIFF_MAGIC" = "52494646" ] \
  || { echo "FAIL: bytes 0-3 '$RIFF_MAGIC' != 52494646 (RIFF)"; exit 1; }
echo "  PASS 1: RIFF magic confirmed"

# ── Check 2: WEBP magic ────────────────────────────────────────────────────────
WEBP_MAGIC=$(read_bytes_hex 8 4)
[ "$WEBP_MAGIC" = "57454250" ] \
  || { echo "FAIL: bytes 8-11 '$WEBP_MAGIC' != 57454250 (WEBP)"; exit 1; }
echo "  PASS 2: WEBP magic confirmed"

# ── Check 3: Exact file size ───────────────────────────────────────────────────
RIFF_SIZE_FIELD=$(read_le32 4)
EXPECTED_SIZE=$(( RIFF_SIZE_FIELD + 8 ))
[ "$ACTUAL_SIZE" -eq "$EXPECTED_SIZE" ] \
  || {
    echo "FAIL: size mismatch — actual=$ACTUAL_SIZE, riff_field=$RIFF_SIZE_FIELD, expected=$EXPECTED_SIZE"
    exit 1
  }
echo "  PASS 3: exact size confirmed (actual=$ACTUAL_SIZE)"

# ── Walk all RIFF chunk headers (reads only FourCC + size fields, not data) ────
CHUNK_LIST=$(walk_riff_chunks)

# ── Check 4: First chunk is a known WebP bitstream FourCC ─────────────────────
FIRST_CHUNK=$(printf '%s\n' "$CHUNK_LIST" | head -1)
case "$FIRST_CHUNK" in
  "56503820") echo "  PASS 4: first chunk VP8  (simple lossy)" ;;
  "5650384c") echo "  PASS 4: first chunk VP8L (simple lossless)" ;;
  "56503858") echo "  PASS 4: first chunk VP8X (extended)" ;;
  *) echo "FAIL: unknown first chunk FourCC '$FIRST_CHUNK' — not VP8 /VP8L/VP8X"; exit 1 ;;
esac

# ── Check 5: ALPH+VP8L forbidden ──────────────────────────────────────────────
# Verified against RIFF chunk headers only — not raw compressed data.
# ALPH (414c5048) is only valid alongside a VP8 bitstream, never VP8L.
HAS_VP8L=false
HAS_ALPH=false
while IFS= read -r CC; do
  [ "$CC" = "5650384c" ] && HAS_VP8L=true
  [ "$CC" = "414c5048" ] && HAS_ALPH=true
done <<< "$CHUNK_LIST"

if [ "$HAS_VP8L" = "true" ] && [ "$HAS_ALPH" = "true" ]; then
  echo "FAIL: ALPH+VP8L combination is forbidden (invalid WebP format)"
  exit 1
fi
echo "  PASS 5: ALPH+VP8L not present"

# ── Check 5a: VP8X must contain exactly one VP8 or VP8L image bitstream ───────
# An extended WebP (VP8X) requires exactly one image bitstream chunk (VP8 or VP8L).
# Zero (header-only file) or two or more bitstream chunks are both invalid.
if [ "$FIRST_CHUNK" = "56503858" ]; then
  BITSTREAM_COUNT=0
  while IFS= read -r CC; do
    if [ "$CC" = "56503820" ] || [ "$CC" = "5650384c" ]; then
      BITSTREAM_COUNT=$(( BITSTREAM_COUNT + 1 ))
    fi
  done <<< "$CHUNK_LIST"
  if [ "$BITSTREAM_COUNT" -eq 0 ]; then
    echo "FAIL: VP8X extended format requires a VP8 or VP8L image bitstream — none found"
    exit 1
  fi
  if [ "$BITSTREAM_COUNT" -gt 1 ]; then
    echo "FAIL: VP8X extended format requires exactly one VP8/VP8L bitstream — found $BITSTREAM_COUNT"
    exit 1
  fi
  echo "  PASS 5a: VP8X contains exactly one VP8/VP8L image bitstream"
fi

# ── Checks 6 & 7: VP8X flags ──────────────────────────────────────────────────
# Only applicable when first chunk is VP8X.
# VP8X chunk data starts at offset 20 (12 header + 4 FourCC + 4 size = 20).
# Flags field: 4 bytes at offset 20, little-endian uint32.
#
# Flag bits (LE uint32, LSB = bit 0; per WebP container spec §Extended File Format):
#   0x01 = Reserved (bit 0, must be 0)
#   0x02 = Animation present (bit 1)
#   0x04 = XMP metadata present (bit 2)
#   0x08 = Exif metadata present (bit 3)
#   0x10 = Alpha channel present (bit 4)
#   0x20 = ICC profile present (bit 5)
#   bits 6–7 and bytes 1–3: Reserved (must be 0)
#
# Our pipeline strips all metadata and sets anim:false.
# Permitted flags in output: only Alpha (0x10). All others must be zero.
# Check: (flags & ~0x10) === 0
if [ "$FIRST_CHUNK" = "56503858" ]; then
  FLAGS_LE_HEX=$(read_bytes_hex 20 4)
  # Parse 4-byte LE uint32
  B0="${FLAGS_LE_HEX:0:2}" B1="${FLAGS_LE_HEX:2:2}" B2="${FLAGS_LE_HEX:4:2}" B3="${FLAGS_LE_HEX:6:2}"
  FLAGS_DEC=$(printf '%d' "0x${B3}${B2}${B1}${B0}")

  # General check: only Alpha flag allowed
  UNEXPECTED=$(( FLAGS_DEC & ~0x10 ))
  [ "$UNEXPECTED" -eq 0 ] \
    || {
      printf 'FAIL: VP8X flags=0x%02x — unexpected bits set (0x%02x != 0); only Alpha (0x10) is permitted\n' \
        "$FLAGS_DEC" "$UNEXPECTED"
      exit 1
    }
  printf '  PASS 6: VP8X flags=0x%02x (only Alpha permitted; all metadata/animation flags clear)\n' "$FLAGS_DEC"

  if [ "$CHECK_NO_ANIM" = "true" ]; then
    ANIM_BIT=$(( FLAGS_DEC & 0x02 ))
    [ "$ANIM_BIT" -eq 0 ] \
      || {
        printf 'FAIL: VP8X Animation flag (0x02) is set in flags=0x%02x — anim:false enforcement failed\n' "$FLAGS_DEC"
        exit 1
      }
    echo "  PASS 7: VP8X Animation flag = 0 (anim:false confirmed)"
  fi
elif [ "$CHECK_NO_ANIM" = "true" ]; then
  # Simple VP8/VP8L formats cannot be animated — flag check trivially passes
  echo "  PASS 7: simple format (VP8/VP8L) — animation structurally impossible"
fi

echo "PASS: $FILE — structural verification complete"
