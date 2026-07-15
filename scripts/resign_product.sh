#!/bin/bash
# Add AVB hashtree footer to product.img (Algorithm NONE)
# E4810 includes product descriptor directly in vbmeta (no signature, hash only)

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
    echo "Usage: $0 <product.img>"
    echo ""
    echo "Example: $0 firmware/custom/product.img"
    exit 1
fi

INPUT="$1"
[ ! -f "$INPUT" ] && echo "Error: $INPUT not found" && exit 1

mkdir -p "$OUTPUT"

# Convert sparse image to raw if needed
if file "$INPUT" | grep -q "Android sparse"; then
    echo "Converting sparse image to raw..."
    simg2img "$INPUT" "$OUTPUT/product.img"
else
    cp "$INPUT" "$OUTPUT/product.img"
fi

echo "=== Adding AVB hashtree to product.img ==="

# Erase existing footer
python3 "$AVB" erase_footer --image "$OUTPUT/product.img" 2>/dev/null || true

# Get stock original image size and partition size
STOCK_PRODUCT="${FIRMWARE}/product.img"
if [ -f "$STOCK_PRODUCT" ]; then
    ORIG_SIZE=$(python3 "$AVB" info_image --image "$STOCK_PRODUCT" 2>/dev/null | grep "Original image size:" | awk '{print $4}')
    PART_SIZE=$(stat -c%s "$STOCK_PRODUCT")
else
    echo "Error: stock product.img not found, cannot determine partition size"
    exit 1
fi

# Resize ext4 to stock original size (leaves room for hashtree + footer)
ORIG_BLOCKS=$((ORIG_SIZE / 4096))
echo "Resizing ext4 to ${ORIG_SIZE} bytes (${ORIG_BLOCKS} blocks)..."
"$E2FSCK" -fy "$OUTPUT/product.img" || true
"$RESIZE2FS" -f "$OUTPUT/product.img" "${ORIG_BLOCKS}" || { echo "ERROR: resize2fs failed"; exit 1; }
truncate -s "$ORIG_SIZE" "$OUTPUT/product.img"

echo "Image size: $ORIG_SIZE bytes"
echo "Partition size: $PART_SIZE bytes"

# Add hashtree footer with Algorithm NONE (no signature, included directly in vbmeta)
python3 "$AVB" add_hashtree_footer \
    --image "$OUTPUT/product.img" \
    --partition_name product \
    --partition_size "$PART_SIZE" \
    --algorithm NONE \
    --hash_algorithm sha1 \
    || { echo "ERROR: Failed to add hashtree"; exit 1; }

echo ""
python3 "$AVB" info_image --image "$OUTPUT/product.img" 2>/dev/null | head -25

# Convert back to sparse if raw
if ! file "$OUTPUT/product.img" | grep -q "Android sparse"; then
    echo "Converting to sparse..."
    img2simg "$OUTPUT/product.img" "$OUTPUT/product_sparse.img"
    mv "$OUTPUT/product_sparse.img" "$OUTPUT/product.img"
fi

echo ""
echo "Output: $OUTPUT/product.img"
echo ""
echo "Next: ./scripts/rebuild_vbmeta.sh"
