#!/bin/bash
# Add AVB hashtree footer to system.img and sign with AOSP testkey
# E4810 chains vbmeta -> system (signed with AOSP testkey RSA2048)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
AVB="$ROOT_DIR/tools/avb-tools/avbtool.py"
KEYS="$ROOT_DIR/keys"
OUTPUT="$ROOT_DIR/output"
FIRMWARE="$ROOT_DIR/firmware/stock"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <system.img>"
    echo ""
    echo "Example: $0 firmware/custom/system_modified.img"
    exit 1
fi

INPUT="$1"
[ ! -f "$INPUT" ] && echo "Error: $INPUT not found" && exit 1

mkdir -p "$OUTPUT"

# Convert sparse image to raw if needed
if file "$INPUT" | grep -q "Android sparse"; then
    echo "Converting sparse image to raw..."
    simg2img "$INPUT" "$OUTPUT/system.img"
else
    cp "$INPUT" "$OUTPUT/system.img"
fi

ANDROID_BINS="$ROOT_DIR/tools/android-bins"
export PATH="$ROOT_DIR/tools/fec:$ANDROID_BINS:$PATH"
E2FSCK="$ANDROID_BINS/e2fsck"
RESIZE2FS="$ANDROID_BINS/resize2fs"

echo "=== Adding AVB hashtree to system.img ==="

# Erase existing footer
python3 "$AVB" erase_footer --image "$OUTPUT/system.img" 2>/dev/null || true

# Get stock original image size and partition size
STOCK_SYSTEM="${FIRMWARE}/system.img"
if [ -f "$STOCK_SYSTEM" ]; then
    ORIG_SIZE=$(python3 "$AVB" info_image --image "$STOCK_SYSTEM" 2>/dev/null | grep "Original image size:" | awk '{print $4}')
    PART_SIZE=$(stat -c%s "$STOCK_SYSTEM")
else
    echo "Error: stock system.img not found, cannot determine partition size"
    exit 1
fi

# Resize ext4 to stock original size (leaves room for hashtree + footer)
ORIG_BLOCKS=$((ORIG_SIZE / 4096))
echo "Resizing ext4 to ${ORIG_SIZE} bytes (${ORIG_BLOCKS} blocks)..."
"$E2FSCK" -fy "$OUTPUT/system.img" || true
"$RESIZE2FS" -f "$OUTPUT/system.img" "${ORIG_BLOCKS}" || { echo "ERROR: resize2fs failed"; exit 1; }
truncate -s "$ORIG_SIZE" "$OUTPUT/system.img"

echo "Image size: $ORIG_SIZE bytes"
echo "Partition size: $PART_SIZE bytes"

# Add hashtree footer signed with AOSP testkey
python3 "$AVB" add_hashtree_footer \
    --image "$OUTPUT/system.img" \
    --partition_name system \
    --partition_size "$PART_SIZE" \
    --key "$KEYS/vbmeta_system.pem" \
    --algorithm SHA256_RSA2048 \
    --hash_algorithm sha1 \
    || { echo "ERROR: Failed to add hashtree"; exit 1; }

echo ""
python3 "$AVB" info_image --image "$OUTPUT/system.img" 2>/dev/null | head -25

# Convert back to sparse if raw
if ! file "$OUTPUT/system.img" | grep -q "Android sparse"; then
    echo "Converting to sparse..."
    img2simg "$OUTPUT/system.img" "$OUTPUT/system_sparse.img"
    mv "$OUTPUT/system_sparse.img" "$OUTPUT/system.img"
fi

echo ""
echo "Output: $OUTPUT/system.img"
echo ""
echo "Next: ./scripts/rebuild_vbmeta.sh"
