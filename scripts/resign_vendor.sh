#!/bin/bash
# Add AVB hashtree footer to vendor.img (Algorithm NONE)
# E4810 includes vendor descriptor directly in vbmeta (no signature, hash only)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
AVB="$ROOT_DIR/tools/avb-tools/avbtool.py"
OUTPUT="$ROOT_DIR/output"
FIRMWARE="$ROOT_DIR/firmware/stock"
ANDROID_BINS="$ROOT_DIR/tools/android-bins"
export PATH="$ROOT_DIR/tools/fec:$ANDROID_BINS:$PATH"
E2FSCK="$ANDROID_BINS/e2fsck"
RESIZE2FS="$ANDROID_BINS/resize2fs"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <vendor.img>"
    echo ""
    echo "Example: $0 firmware/custom/vendor.img"
    exit 1
fi

INPUT="$1"
[ ! -f "$INPUT" ] && echo "Error: $INPUT not found" && exit 1

mkdir -p "$OUTPUT"

# Convert sparse image to raw if needed
if file "$INPUT" | grep -q "Android sparse"; then
    echo "Converting sparse image to raw..."
    simg2img "$INPUT" "$OUTPUT/vendor.img"
else
    cp "$INPUT" "$OUTPUT/vendor.img"
fi

echo "=== Adding AVB hashtree to vendor.img ==="

# Erase existing footer
python3 "$AVB" erase_footer --image "$OUTPUT/vendor.img" 2>/dev/null || true

# Get stock original image size and partition size
STOCK_VENDOR="${FIRMWARE}/vendor.img"
if [ -f "$STOCK_VENDOR" ]; then
    ORIG_SIZE=$(python3 "$AVB" info_image --image "$STOCK_VENDOR" 2>/dev/null | grep "Original image size:" | awk '{print $4}')
    PART_SIZE=$(stat -c%s "$STOCK_VENDOR")
else
    echo "Error: stock vendor.img not found, cannot determine partition size"
    exit 1
fi

# Resize ext4 to stock original size (leaves room for hashtree + footer)
ORIG_BLOCKS=$((ORIG_SIZE / 4096))
echo "Resizing ext4 to ${ORIG_SIZE} bytes (${ORIG_BLOCKS} blocks)..."
"$E2FSCK" -fy "$OUTPUT/vendor.img" || true
"$RESIZE2FS" -f "$OUTPUT/vendor.img" "${ORIG_BLOCKS}" || { echo "ERROR: resize2fs failed"; exit 1; }
truncate -s "$ORIG_SIZE" "$OUTPUT/vendor.img"

echo "Image size: $ORIG_SIZE bytes"
echo "Partition size: $PART_SIZE bytes"

# Add hashtree footer with Algorithm NONE (no signature, included directly in vbmeta)
python3 "$AVB" add_hashtree_footer \
    --image "$OUTPUT/vendor.img" \
    --partition_name vendor \
    --partition_size "$PART_SIZE" \
    --algorithm NONE \
    --hash_algorithm sha1 \
    || { echo "ERROR: Failed to add hashtree"; exit 1; }

echo ""
python3 "$AVB" info_image --image "$OUTPUT/vendor.img" 2>/dev/null | head -25

# Convert back to sparse if raw
if ! file "$OUTPUT/vendor.img" | grep -q "Android sparse"; then
    echo "Converting to sparse..."
    img2simg "$OUTPUT/vendor.img" "$OUTPUT/vendor_sparse.img"
    mv "$OUTPUT/vendor_sparse.img" "$OUTPUT/vendor.img"
fi

echo ""
echo "Output: $OUTPUT/vendor.img"
echo ""
echo "Next: ./scripts/rebuild_vbmeta.sh"
