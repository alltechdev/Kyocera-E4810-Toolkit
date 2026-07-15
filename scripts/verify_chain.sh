#!/bin/bash
# Verify E4810 AVB chain before flashing
# Verifies output images against firmware/stock

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
AVB="$ROOT_DIR/tools/avb-tools/avbtool.py"
OUTPUT="$ROOT_DIR/output"
STOCK="$ROOT_DIR/firmware/stock"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ERRORS=$((ERRORS+1)); }

ERRORS=0

echo "=== E4810 AVB Chain Verification ==="
echo "Comparing output/ against firmware/stock/"
echo ""

# Get stock vbmeta info
STOCK_VBMETA=$(python3 "$AVB" info_image --image "$STOCK/vbmeta.img" 2>/dev/null)
STOCK_VBMETA_KEY=$(echo "$STOCK_VBMETA" | grep "Public key (sha1)" | head -1 | awk '{print $4}')

# ========== STOCK FIRMWARE VERIFICATION ==========
echo "=== Verifying Stock Firmware ==="
echo ""

# Stock vbmeta key
echo "Stock vbmeta.img..."
if [ "$STOCK_VBMETA_KEY" = "2597c218aae470a130f61162feaae70afd97f011" ]; then
    pass "stock vbmeta uses expected RSA4096 key"
else
    fail "stock vbmeta key unexpected: $STOCK_VBMETA_KEY"
fi

# Stock system.img
echo "Stock system.img..."
SYS_KEY=$(python3 "$AVB" info_image --image "$STOCK/system.img" 2>/dev/null | grep "Public key (sha1)" | awk '{print $4}')
if [ "$SYS_KEY" = "cdbb77177f731920bbe0a0f94f84d9038ae0617d" ]; then
    pass "stock system.img uses AOSP testkey"
else
    fail "stock system.img key unexpected: $SYS_KEY"
fi

# Stock boot.img
echo "Stock boot.img..."
STOCK_BOOT=$(python3 "$AVB" info_image --image "$STOCK/boot.img" 2>/dev/null)
if echo "$STOCK_BOOT" | grep -q "Algorithm:.*NONE"; then
    pass "stock boot.img has Algorithm NONE"
else
    fail "stock boot.img algorithm unexpected"
fi

# Stock dtbo.img
echo "Stock dtbo.img..."
STOCK_DTBO=$(python3 "$AVB" info_image --image "$STOCK/dtbo.img" 2>/dev/null)
if echo "$STOCK_DTBO" | grep -q "Partition Name:.*dtbo"; then
    pass "stock dtbo.img has valid footer"
else
    fail "stock dtbo.img footer invalid"
fi

# Stock vendor.img
echo "Stock vendor.img..."
STOCK_VENDOR=$(python3 "$AVB" info_image --image "$STOCK/vendor.img" 2>/dev/null)
if echo "$STOCK_VENDOR" | grep -q "Partition Name:.*vendor"; then
    pass "stock vendor.img has valid footer"
else
    fail "stock vendor.img footer invalid"
fi

# Stock product.img
echo "Stock product.img..."
STOCK_PRODUCT=$(python3 "$AVB" info_image --image "$STOCK/product.img" 2>/dev/null)
if echo "$STOCK_PRODUCT" | grep -q "Partition Name:.*product"; then
    pass "stock product.img has valid footer"
else
    fail "stock product.img footer invalid"
fi

# ========== OUTPUT VERIFICATION ==========
echo ""
echo "=== Verifying Output Images ==="
echo ""

# Check output/vbmeta.img exists
if [ ! -f "$OUTPUT/vbmeta.img" ]; then
    fail "output/vbmeta.img not found"
    echo ""
    echo -e "${RED}Run ./scripts/rebuild_vbmeta.sh first${NC}"
    exit 1
fi

# Output vbmeta size
SIZE=$(stat -c%s "$OUTPUT/vbmeta.img")
if [ "$SIZE" -ge 3000 ]; then
    pass "output vbmeta.img size OK ($SIZE bytes)"
else
    fail "output vbmeta.img too small ($SIZE < 3000)"
fi

# Output vbmeta key matches stock
OUT_VBMETA=$(python3 "$AVB" info_image --image "$OUTPUT/vbmeta.img" 2>/dev/null)
OUT_VBMETA_KEY=$(echo "$OUT_VBMETA" | grep "Public key (sha1)" | head -1 | awk '{print $4}')
if [ "$OUT_VBMETA_KEY" = "$STOCK_VBMETA_KEY" ]; then
    pass "output vbmeta key matches stock"
else
    fail "output vbmeta key mismatch: $OUT_VBMETA_KEY"
fi

# Check all descriptors present
for part in boot dtbo vendor product; do
    if echo "$OUT_VBMETA" | grep -q "Partition Name:.*$part"; then
        pass "$part descriptor present"
    else
        fail "$part descriptor missing"
    fi
done

# System chain present with correct key
CHAIN_KEY=$(echo "$OUT_VBMETA" | grep -A3 "Partition Name:.*system" | grep "Public key (sha1)" | awk '{print $4}')
if [ "$CHAIN_KEY" = "cdbb77177f731920bbe0a0f94f84d9038ae0617d" ]; then
    pass "system chain uses AOSP testkey"
else
    fail "system chain key mismatch: $CHAIN_KEY"
fi

# ========== HASH COMPARISON ==========
echo ""
echo "=== Comparing Hashes Against Stock ==="
echo ""

# dtbo hash
DTBO_STOCK=$(echo "$STOCK_VBMETA" | grep -A5 "Partition Name:.*dtbo" | grep "Digest:" | awk '{print $2}')
DTBO_OUT=$(echo "$OUT_VBMETA" | grep -A5 "Partition Name:.*dtbo" | grep "Digest:" | awk '{print $2}')
if [ "$DTBO_STOCK" = "$DTBO_OUT" ]; then
    pass "dtbo hash matches stock"
else
    fail "dtbo hash mismatch"
fi

# vendor hash
VENDOR_STOCK=$(echo "$STOCK_VBMETA" | grep -A10 "Partition Name:.*vendor" | grep "Root Digest:" | awk '{print $3}')
VENDOR_OUT=$(echo "$OUT_VBMETA" | grep -A10 "Partition Name:.*vendor" | grep "Root Digest:" | awk '{print $3}')
if [ "$VENDOR_STOCK" = "$VENDOR_OUT" ]; then
    pass "vendor hash matches stock"
elif [ -f "$OUTPUT/vendor.img" ]; then
    VENDOR_IMG_DIGEST=$(python3 "$AVB" info_image --image "$OUTPUT/vendor.img" 2>/dev/null | grep "Root Digest:" | awk '{print $3}')
    if [ "$VENDOR_OUT" = "$VENDOR_IMG_DIGEST" ]; then
        pass "vendor hash matches custom vendor.img (modified)"
    else
        fail "vendor hash mismatch: vbmeta=$VENDOR_OUT img=$VENDOR_IMG_DIGEST"
    fi
else
    fail "vendor hash mismatch"
fi

# product hash
PRODUCT_STOCK=$(echo "$STOCK_VBMETA" | grep -A10 "Partition Name:.*product" | grep "Root Digest:" | awk '{print $3}')
PRODUCT_OUT=$(echo "$OUT_VBMETA" | grep -A10 "Partition Name:.*product" | grep "Root Digest:" | awk '{print $3}')
if [ "$PRODUCT_STOCK" = "$PRODUCT_OUT" ]; then
    pass "product hash matches stock"
elif [ -f "$OUTPUT/product.img" ]; then
    # Custom product - verify vbmeta descriptor matches the image footer
    PRODUCT_IMG_DIGEST=$(python3 "$AVB" info_image --image "$OUTPUT/product.img" 2>/dev/null | grep "Root Digest:" | awk '{print $3}')
    if [ "$PRODUCT_OUT" = "$PRODUCT_IMG_DIGEST" ]; then
        pass "product hash matches custom product.img (modified)"
    else
        fail "product hash mismatch: vbmeta=$PRODUCT_OUT img=$PRODUCT_IMG_DIGEST"
    fi
else
    fail "product hash mismatch"
fi

# ========== BOOT IMAGE ==========
echo ""
echo "=== Verifying Boot Image ==="
echo ""

if [ -f "$OUTPUT/boot.img" ]; then
    BOOT_FOOTER=$(python3 "$AVB" info_image --image "$OUTPUT/boot.img" 2>/dev/null)

    # Algorithm NONE
    if echo "$BOOT_FOOTER" | grep -q "Algorithm:.*NONE"; then
        pass "output boot.img has Algorithm NONE"
    else
        fail "output boot.img algorithm incorrect"
    fi

    # Boot hash matches vbmeta
    BOOT_HASH_IMG=$(echo "$BOOT_FOOTER" | grep -A5 "Partition Name:.*boot" | grep "Digest:" | awk '{print $2}')
    BOOT_HASH_VBMETA=$(echo "$OUT_VBMETA" | grep -A5 "Partition Name:.*boot" | grep "Digest:" | awk '{print $2}')
    if [ "$BOOT_HASH_IMG" = "$BOOT_HASH_VBMETA" ]; then
        pass "boot hash in vbmeta matches boot.img"
    else
        fail "boot hash mismatch: img=$BOOT_HASH_IMG vbmeta=$BOOT_HASH_VBMETA"
    fi
else
    fail "output/boot.img not found"
fi

# ========== SUMMARY ==========
echo ""
echo "========================================="
if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}All checks passed!${NC}"
    echo ""
    echo "Ready to flash:"
    echo "  $OUTPUT/boot.img"
    echo "  $OUTPUT/vbmeta.img"
else
    echo -e "${RED}$ERRORS check(s) failed${NC}"
    exit 1
fi
