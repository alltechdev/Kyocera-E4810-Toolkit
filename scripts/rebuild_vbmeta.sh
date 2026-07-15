#!/bin/bash
# Rebuild vbmeta.img for E4810 with modified boot/system
# Signs with RSA4096 key, chains to system (RSA2048)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
AVB="$ROOT_DIR/tools/avb-tools/avbtool.py"
KEYS="$ROOT_DIR/keys"
OUTPUT="$ROOT_DIR/output"
FIRMWARE="$ROOT_DIR/firmware/stock"

echo "=== Rebuilding vbmeta.img for E4810 ==="

# Use patched images from output/ if they exist, otherwise stock
BOOT="${OUTPUT}/boot.img"
SYSTEM="${OUTPUT}/system.img"
DTBO="${FIRMWARE}/dtbo.img"
VENDOR="${OUTPUT}/vendor.img"
PRODUCT="${OUTPUT}/product.img"

[ ! -f "$BOOT" ] && BOOT="${FIRMWARE}/boot.img"
[ ! -f "$SYSTEM" ] && SYSTEM="${FIRMWARE}/system.img"
[ ! -f "$VENDOR" ] && VENDOR="${FIRMWARE}/vendor.img"
[ ! -f "$PRODUCT" ] && PRODUCT="${FIRMWARE}/product.img"

echo "Boot:    $BOOT"
echo "System:  $SYSTEM"
echo "DTBO:    $DTBO"
echo "Vendor:  $VENDOR"
echo "Product: $PRODUCT"

for img in "$BOOT" "$DTBO" "$VENDOR" "$PRODUCT" "$SYSTEM"; do
    [ ! -f "$img" ] && echo "Error: $img not found" && exit 1
done

mkdir -p "$OUTPUT"

echo ""
echo "Building vbmeta.img..."

python3 "$AVB" make_vbmeta_image \
    --output "$OUTPUT/vbmeta.img" \
    --key "$KEYS/vbmeta.pem" \
    --algorithm SHA256_RSA4096 \
    --include_descriptors_from_image "$BOOT" \
    --include_descriptors_from_image "$DTBO" \
    --include_descriptors_from_image "$VENDOR" \
    --include_descriptors_from_image "$PRODUCT" \
    --chain_partition system:2:"$KEYS/system.avbpubkey" \
    || { echo "ERROR: Failed to build vbmeta"; exit 1; }

echo ""
python3 "$AVB" info_image --image "$OUTPUT/vbmeta.img" 2>/dev/null | head -40

echo ""
echo "Output: $OUTPUT/vbmeta.img"
echo ""
echo "=== Flash these images ==="
echo "  fastboot flash boot $OUTPUT/boot.img"
[ -f "$OUTPUT/system.img" ] && echo "  fastboot flash system $OUTPUT/system.img"
echo "  fastboot flash vbmeta $OUTPUT/vbmeta.img"
echo ""
echo "Next: ./scripts/verify_chain.sh"
