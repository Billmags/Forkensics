#!/usr/bin/env bash
# fixtures/generate-fixtures.sh — forkensics-image-spike Rev 10 (IMv7 fix)
# Creates all 5 spike fixtures and proves preconditions before upload.
# Exits 1 if ANY precondition fails — do not upload partial fixtures.
#
# Run from cf-spike/: ./fixtures/generate-fixtures.sh
# Requires: ImageMagick 7+ (magick), exiftool, Bash 4+

set -euo pipefail

# ── Bash version guard ─────────────────────────────────────────────────────────
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || {
  echo "FAIL: Bash 4+ required (found ${BASH_VERSION:-unknown})"
  echo "  macOS: brew install bash && /opt/homebrew/bin/bash fixtures/generate-fixtures.sh"
  exit 1
}

# ── Dependency check ───────────────────────────────────────────────────────────
for cmd in magick exiftool img2webp; do
  command -v "$cmd" >/dev/null \
    || { echo "FAIL: $cmd not installed (brew install imagemagick exiftool webp)"; exit 1; }
done

mkdir -p fixtures
cd fixtures

echo "=== generate-fixtures.sh ==="

# ── fixture-exif.jpg: JPEG with GPS + EXIF metadata ───────────────────────────
echo "Generating fixture-exif.jpg …"
# Create plain JPEG (IMv7: -set EXIF: is unreliable; embed all tags via exiftool)
magick \
  -size 1200x900 gradient:blue-red \
  -quality 85 \
  fixture-exif-base.jpg

# Embed ALL EXIF + GPS tags via exiftool
exiftool -overwrite_original \
  -Make="TestCamera" \
  -Model="SpikeModel1" \
  -DateTimeOriginal="2026:08:15 12:00:00" \
  -GPSLatitude="37.7749" \
  -GPSLatitudeRef="N" \
  -GPSLongitude="122.4194" \
  -GPSLongitudeRef="W" \
  -GPSAltitude="10" \
  fixture-exif-base.jpg
mv fixture-exif-base.jpg fixture-exif.jpg

# Precondition proof: EXIF (IFD0 or ExifIFD) and GPS groups must both be present.
# With -G1, exiftool outputs [IFD0]/[ExifIFD] for EXIF data and [GPS] for GPS —
# it never outputs bare [EXIF] at Group 1 level.
EXIF_OUT=$(exiftool -G1 -s fixture-exif.jpg)
printf '%s\n' "$EXIF_OUT" | grep -qE "^\[(IFD0|ExifIFD)\]" \
  || { echo "FAIL: fixture-exif.jpg missing EXIF data (no IFD0/ExifIFD group)"; exit 1; }
printf '%s\n' "$EXIF_OUT" | grep -q "^\[GPS\]" \
  || { echo "FAIL: fixture-exif.jpg missing [GPS] group"; exit 1; }
echo "PASS: fixture-exif.jpg — EXIF (IFD0/ExifIFD) and [GPS] confirmed"

# ── fixture-static-icc-xmp.webp: Static WebP with ICC + XMP ──────────────────
echo "Generating fixture-static-icc-xmp.webp …"
magick \
  -size 1000x800 gradient:green-yellow \
  -profile /System/Library/ColorSync/Profiles/sRGB\ Profile.icc \
  fixture-static-base.png 2>/dev/null || \
magick \
  -size 1000x800 gradient:green-yellow \
  fixture-static-base.png

exiftool -overwrite_original \
  -XMP:Creator="ForkensicsSpike" \
  -XMP:Description="Test fixture with ICC and XMP" \
  fixture-static-base.png

magick fixture-static-base.png -quality 85 fixture-static-icc-xmp.webp
rm -f fixture-static-base.png

# Embed ICC profile in the WebP if not already present
if ! exiftool -G1 -s fixture-static-icc-xmp.webp | grep -q "^\[ICC_Profile\]"; then
  magick fixture-static-icc-xmp.webp \
    -profile /System/Library/ColorSync/Profiles/sRGB\ Profile.icc \
    fixture-static-icc-xmp-tmp.webp 2>/dev/null \
    && mv fixture-static-icc-xmp-tmp.webp fixture-static-icc-xmp.webp \
    || true
fi

# Ensure XMP is embedded
exiftool -overwrite_original \
  -XMP:Creator="ForkensicsSpike" \
  -XMP:Description="Test fixture with ICC and XMP" \
  fixture-static-icc-xmp.webp

# Precondition proof: [ICC_Profile] and [XMP] groups must both be present
SWEBP_OUT=$(exiftool -G1 -s fixture-static-icc-xmp.webp)
printf '%s\n' "$SWEBP_OUT" | grep -q "^\[ICC_Profile\]" \
  || { echo "FAIL: fixture-static-icc-xmp.webp missing [ICC_Profile] group"; exit 1; }
printf '%s\n' "$SWEBP_OUT" | grep -qiE "^\[XMP" \
  || { echo "FAIL: fixture-static-icc-xmp.webp missing [XMP] group"; exit 1; }
echo "PASS: fixture-static-icc-xmp.webp — [ICC_Profile] and [XMP] confirmed"

# ── fixture-animated.webp: Animated WebP ─────────────────────────────────────
# Pipeline: magick → PNG frames → cwebp → individual .webp → webpmux → animated.
# cwebp + webpmux (brew install webp) guarantee ANMF-based animated WebP output.
# img2webp produces degenerate 122-byte files on macOS with PNG gradient input.
echo "Generating fixture-animated.webp …"
for i in 1 2 3; do
  magick -size 400x300 "gradient:blue-cyan" "frame_src_${i}.png"
  cwebp -q 80 "frame_src_${i}.png" -o "frame_${i}.webp" 2>/dev/null
  rm -f "frame_src_${i}.png"
done
webpmux \
  -frame frame_1.webp +300 \
  -frame frame_2.webp +300 \
  -frame frame_3.webp +300 \
  -loop 0 \
  -o fixture-animated.webp
rm -f frame_1.webp frame_2.webp frame_3.webp

# Precondition proof: ANMF fourcc present in binary (ASCII "ANMF" = animated WebP frame chunk).
# grep -qa searches binary file for the ASCII fourcc string — reliable on both macOS and Linux.
# FrameCount from exiftool is a secondary check; used for the pass message only.
FRAME_COUNT=$(exiftool -n -s3 -FrameCount fixture-animated.webp 2>/dev/null || echo "0")
FRAME_COUNT="${FRAME_COUNT:-0}"
if grep -qa "ANMF" fixture-animated.webp 2>/dev/null; then
  echo "PASS: fixture-animated.webp — ANMF chunk present (animated; FrameCount=$FRAME_COUNT)"
elif [ "$FRAME_COUNT" -gt 1 ] 2>/dev/null; then
  echo "PASS: fixture-animated.webp — FrameCount=$FRAME_COUNT (animated)"
else
  echo "FAIL: fixture-animated.webp does not appear to be animated (FrameCount=$FRAME_COUNT, no ANMF chunk)"
  exit 1
fi

# ── fixture-oversized-px.jpg: > 15.5 MP AND ≤ 10 MB ──────────────────────────
# Target: 4000×4000 = 16,000,000 px (> 15,500,000), compressed to stay under 10 MB.
# Use low-detail gradient so JPEG compression keeps file small.
echo "Generating fixture-oversized-px.jpg …"
magick \
  -size 4000x4000 gradient:gray10-gray20 \
  -quality 40 \
  fixture-oversized-px.jpg

# Precondition proof: pixel area > 15,500,000 AND file_size ≤ 10,485,760
PIXEL_W=$(exiftool -n -s3 -ImageWidth  fixture-oversized-px.jpg)
PIXEL_H=$(exiftool -n -s3 -ImageHeight fixture-oversized-px.jpg)
PIXEL_AREA=$(( PIXEL_W * PIXEL_H ))
PIXEL_SIZE=$(wc -c < fixture-oversized-px.jpg | tr -d ' ')

[ "$PIXEL_AREA" -gt 15500000 ] \
  || { echo "FAIL: fixture-oversized-px.jpg area $PIXEL_AREA <= 15,500,000 (pixel gate would not fire)"; exit 1; }
[ "$PIXEL_SIZE" -le 10485760 ] \
  || { echo "FAIL: fixture-oversized-px.jpg size $PIXEL_SIZE > 10,485,760 — byte gate fires first (reduce quality or dimensions)"; exit 1; }
echo "PASS: fixture-oversized-px.jpg — area=$PIXEL_AREA (>15.5 MP) size=$PIXEL_SIZE (<=10 MB)"

# ── fixture-oversized.jpg: > 10 MB (byte-size gate) ──────────────────────────
# Target: high-res, high-quality JPEG that compresses poorly.
echo "Generating fixture-oversized.jpg …"
magick \
  -size 5000x3000 plasma:fractal \
  -quality 98 \
  fixture-oversized.jpg

# If still under 10 MB, increase resolution
OVERSIZE=$(wc -c < fixture-oversized.jpg | tr -d ' ')
if [ "$OVERSIZE" -le 10485760 ]; then
  magick \
    -size 7000x4500 plasma:fractal \
    -quality 98 \
    fixture-oversized.jpg
fi

# Precondition proof: file_size > 10,485,760
OVERSIZE=$(wc -c < fixture-oversized.jpg | tr -d ' ')
[ "$OVERSIZE" -gt 10485760 ] \
  || { echo "FAIL: fixture-oversized.jpg size $OVERSIZE <= 10,485,760 (byte gate would not fire)"; exit 1; }
echo "PASS: fixture-oversized.jpg — size=$OVERSIZE (>10 MB)"

echo ""
echo "=== All fixtures generated and preconditions verified ==="
echo "  fixture-exif.jpg"
echo "  fixture-static-icc-xmp.webp"
echo "  fixture-animated.webp"
echo "  fixture-oversized-px.jpg"
echo "  fixture-oversized.jpg"
