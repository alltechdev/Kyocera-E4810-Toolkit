#!/bin/bash
# Prepare partition images from output/ for OTA payload generation
#
# IMPORTANT: Images KEEP their AVB hashtree footers. The OTA must write
# the exact bytes the partition needs, including AVB data. Only vbmeta
# is used as-is (it IS the footer).
#
# When updating any partition (system, vendor, product), you MUST also
# include vbmeta - the hashtree descriptors must match.
#
# Usage: ./scripts/prepare_images.sh [partition ...]
# Examples:
#   ./scripts/prepare_images.sh vbmeta              # Tiny test update
#   ./scripts/prepare_images.sh product vbmeta       # Product + matching vbmeta
#   ./scripts/prepare_images.sh all                  # Full update (slow)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATOR_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$CREATOR_DIR")"
OUTPUT_DIR="$ROOT_DIR/output"
RAW_DIR="$CREATOR_DIR/raw_images"
AVB="$ROOT_DIR/tools/avb-tools/avbtool.py"

# Actual partition sizes on E4810 (from blockdev --getsize64)
# Images are padded to these sizes so the payload fills the whole partition
declare -A PART_SIZES=(
    [vbmeta]=65536
    [boot]=33554432
    [system]=922746880
    [vendor]=524288000
    [product]=524288000
    [dtbo]=1310720
)

# Sparse images that need simg2img conversion
SPARSE_PARTS="system vendor product"

mkdir -p "$RAW_DIR"

prepare_partition() {
    local part="$1"
    local src="$OUTPUT_DIR/${part}.img"
    local dst="$RAW_DIR/${part}.img"
    local size="${PART_SIZES[$part]}"

    if [ ! -f "$src" ]; then
        echo "SKIP: $src not found"
        return
    fi

    echo "Preparing $part..."

    # Convert sparse to raw if needed (keeps AVB footer intact)
    if echo "$SPARSE_PARTS" | grep -qw "$part"; then
        if file "$src" | grep -q "Android sparse"; then
            echo "  Converting sparse to raw (keeping AVB footer)..."
            simg2img "$src" "$dst"
        else
            cp "$src" "$dst"
        fi
    else
        cp "$src" "$dst"
    fi

    # DO NOT strip AVB footer - the OTA must write the full partition
    # including hashtree + FEC data. Only vbmeta has no footer to strip.

    # Pad to partition size
    if [ -n "$size" ]; then
        local current_size=$(stat -c%s "$dst")
        if [ "$current_size" -lt "$size" ]; then
            echo "  Padding from $current_size to $size bytes"
            truncate -s "$size" "$dst"
        elif [ "$current_size" -gt "$size" ]; then
            echo "  WARNING: Image ($current_size) larger than partition ($size)!"
        fi
    fi

    echo "  Ready: $dst ($(stat -c%s "$dst") bytes)"
}

# Parse arguments
if [ $# -eq 0 ]; then
    echo "Usage: $0 <partition ...>"
    echo "  Partitions: vbmeta boot system vendor product dtbo all"
    echo ""
    echo "Examples:"
    echo "  $0 vbmeta              # Tiny test update (vbmeta only)"
    echo "  $0 product vbmeta      # Product + matching vbmeta"
    echo "  $0 all                 # Full update (slow)"
    echo ""
    echo "IMPORTANT: When updating system/vendor/product, always include vbmeta."
    exit 1
fi

PARTS=("$@")
if [ "${PARTS[0]}" = "all" ]; then
    PARTS=(boot system vendor product vbmeta)
fi

# Warn if updating a partition without vbmeta
HAS_VBMETA=false
HAS_OTHER=false
for part in "${PARTS[@]}"; do
    if [ "$part" = "vbmeta" ]; then HAS_VBMETA=true; fi
    if [ "$part" != "vbmeta" ] && [ "$part" != "boot" ]; then HAS_OTHER=true; fi
done
if $HAS_OTHER && ! $HAS_VBMETA; then
    echo "WARNING: Updating system/vendor/product without vbmeta will cause bootloop!"
    echo "         Add 'vbmeta' to your partition list."
    echo ""
fi

echo "=== Preparing Raw Images ==="
for part in "${PARTS[@]}"; do
    prepare_partition "$part"
done

echo ""
echo "Raw images ready in $RAW_DIR/"
echo ""
echo "IMPORTANT: Filenames become partition names in the OTA."
echo "  product.img -> writes to partition 'product'"
echo "  Do NOT rename files (e.g., product_new.img will fail)."
echo ""
echo "Next: ./scripts/build_ota.sh"
