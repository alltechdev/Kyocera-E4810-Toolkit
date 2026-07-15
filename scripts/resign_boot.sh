#!/bin/bash
# Add AVB hash footer to boot.img (e.g., after Magisk patching)
# E4810 uses Algorithm: NONE - hash is stored in vbmeta

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
AVB="$ROOT_DIR/tools/avb-tools/avbtool.py"
OUTPUT="$ROOT_DIR/output"

PART_SIZE=33554432  # 32MB boot partition

if [ $# -lt 1 ]; then
    echo "Usage: $0 <boot.img>"
    echo ""
    echo "Example: $0 /path/to/magisk_patched_boot.img"
    exit 1
fi

INPUT="$1"
[ ! -f "$INPUT" ] && echo "Error: $INPUT not found" && exit 1

mkdir -p "$OUTPUT"
cp "$INPUT" "$OUTPUT/boot.img"

echo "=== Adding AVB hash footer to boot.img ==="

# Erase existing footer
python3 "$AVB" erase_footer --image "$OUTPUT/boot.img" 2>/dev/null || true

# Add hash footer with Algorithm NONE
python3 "$AVB" add_hash_footer \
    --image "$OUTPUT/boot.img" \
    --partition_name boot \
    --partition_size "$PART_SIZE" \
    --algorithm NONE || { echo "ERROR: Failed to add hash footer"; exit 1; }

echo ""
python3 "$AVB" info_image --image "$OUTPUT/boot.img" 2>/dev/null | head -20

echo ""
echo "Output: $OUTPUT/boot.img"
echo ""
echo "Next: ./scripts/rebuild_vbmeta.sh"
