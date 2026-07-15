#!/bin/bash
# Resign all APKs in custom firmware images with app keystore
# Mounts system/product/vendor, finds all .apk files, resigns with apksigner

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
KEYSTORE="$ROOT_DIR/app_keystore/platform.jks"
KS_ALIAS="platform"
KS_PASS="${KEY_PASS:-changeit}"
CUSTOM="$ROOT_DIR/firmware/custom"

if [ ! -f "$KEYSTORE" ]; then
    echo "Error: keystore not found at $KEYSTORE"
    exit 1
fi

FAILED=0
SIGNED=0
SKIPPED=0

resign_apks_in_image() {
    local IMG="$1"
    local NAME="$2"
    local MNT="/tmp/e4810_${NAME}_mnt"

    if [ ! -f "$IMG" ]; then
        echo "Skipping $NAME - $IMG not found"
        return
    fi

    echo ""
    echo "=== Processing $NAME ==="

    # Convert sparse to raw if needed
    local RAW_IMG="$IMG"
    if file "$IMG" | grep -q "Android sparse"; then
        echo "Converting sparse to raw..."
        RAW_IMG="/tmp/e4810_${NAME}_raw.img"
        simg2img "$IMG" "$RAW_IMG"
    fi

    # Erase AVB footer to get raw ext4
    python3 "$ROOT_DIR/tools/avb-tools/avbtool.py" erase_footer --image "$RAW_IMG" 2>/dev/null || true

    # Mount
    mkdir -p "$MNT"
    sudo mount -o loop "$RAW_IMG" "$MNT" || { echo "ERROR: Failed to mount $NAME"; return; }

    # Find and resign all APKs
    local apk_list
    apk_list=$(find "$MNT" -name "*.apk" -type f 2>/dev/null)
    local count=$(echo "$apk_list" | grep -c . || true)
    echo "Found $count APKs in $NAME"

    while IFS= read -r apk; do
        [ -z "$apk" ] && continue
        local rel="${apk#$MNT}"

        # Skip CTS shim packages (hardcoded signature checks in PackageManagerService)
        local basename=$(basename "$apk")
        if [ "$basename" = "CtsShimPrebuilt.apk" ] || [ "$basename" = "CtsShimPrivPrebuilt.apk" ]; then
            echo "  [SKIP] $rel (CTS shim - hardcoded sig)"
            SKIPPED=$((SKIPPED+1))
            continue
        fi

        # Check if already signed with our key
        if apksigner verify --print-certs "$apk" 2>/dev/null | grep -q "example-platform"; then
            echo "  [SKIP] $rel (already signed)"
            SKIPPED=$((SKIPPED+1))
            continue
        fi

        # Resign with v3 only (matching original stock scheme)
        local tmpapk="/tmp/e4810_resign_tmp.apk"
        cp "$apk" "$tmpapk"

        if apksigner sign \
            --ks "$KEYSTORE" \
            --ks-key-alias "$KS_ALIAS" \
            --ks-pass "pass:$KS_PASS" \
            --key-pass "pass:$KS_PASS" \
            --v1-signing-enabled false \
            --v2-signing-enabled false \
            --v3-signing-enabled true \
            "$tmpapk" 2>/dev/null; then
            sudo cp "$tmpapk" "$apk"
            echo "  [OK] $rel"
            SIGNED=$((SIGNED+1))
        else
            echo "  [FAIL] $rel"
            FAILED=$((FAILED+1))
        fi
        rm -f "$tmpapk" "${tmpapk}.idsig"
    done <<< "$apk_list"

    # Unmount
    sudo umount "$MNT"
    rmdir "$MNT"

    # If we converted from sparse, copy back
    if [ "$RAW_IMG" != "$IMG" ]; then
        echo "Converting back to sparse..."
        img2simg "$RAW_IMG" "$IMG"
        rm -f "$RAW_IMG"
    fi
}

resign_apks_in_image "$CUSTOM/system.img" "system"
resign_apks_in_image "$CUSTOM/product.img" "product"
resign_apks_in_image "$CUSTOM/vendor.img" "vendor"

echo ""
echo "========================================="
echo "Signed: $SIGNED | Skipped: $SKIPPED | Failed: $FAILED"
echo "========================================="

if [ $FAILED -gt 0 ]; then
    exit 1
fi
