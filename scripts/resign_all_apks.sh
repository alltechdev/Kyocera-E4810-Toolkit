#!/bin/bash
# Resign all APKs and JARs using signapk.jar
# Must run as root: sudo ./scripts/resign_all_apks.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SECDIR="$ROOT_DIR/certs/aosp"
SIGNAPK="$ROOT_DIR/ROM_resigner/signapk.jar"
SIGNAPK_LIBS="$ROOT_DIR/ROM_resigner/Linux"
CUSTOM="$ROOT_DIR/firmware/custom"

# KEY_PASS environment variable for keystore password
KEY_PASS="${KEY_PASS:-changeit}"

CERT="$SECDIR/platform.x509.pem"
KEY="$SECDIR/platform.pk8"

SIGNED=0
FAILED=0
SKIPPED=0

sign_partition() {
    local IMG="$1"
    local NAME="$2"

    [ ! -f "$IMG" ] && echo "Skipping $NAME - not found" && return

    echo ""
    echo "=== $NAME ==="

    local RAW="/tmp/e4810_${NAME}_raw.img"
    local MNT="/tmp/e4810_${NAME}_mnt"

    # Convert sparse if needed
    if file "$IMG" | grep -q "Android sparse"; then
        simg2img "$IMG" "$RAW"
    else
        cp "$IMG" "$RAW"
    fi
    python3 "$ROOT_DIR/tools/avb-tools/avbtool.py" erase_footer --image "$RAW" 2>/dev/null || true

    mkdir -p "$MNT"
    mount -o loop "$RAW" "$MNT"

    # Sign all APKs and JARs
    find "$MNT" -type f -name "*.apk" | sort | while read -r file; do
        local rel="${file#$MNT}"
        local base=$(basename "$file")

        # Skip CTS shims
        if [ "$base" = "CtsShimPrebuilt.apk" ] || [ "$base" = "CtsShimPrivPrebuilt.apk" ]; then
            echo "  [SKIP] $rel"
            continue
        fi

        local tmp="/tmp/e4810_sign_tmp.apk"
        cp "$file" "$tmp"
        chmod 644 "$tmp"

        if apksigner sign \
            --ks "$ROOT_DIR/app_keystore/platform.jks" \
            --ks-key-alias platform \
            --ks-pass pass:$KEY_PASS \
            --key-pass pass:$KEY_PASS \
            --v1-signing-enabled false \
            --v2-signing-enabled false \
            --v3-signing-enabled true \
            "$tmp" 2>/dev/null; then
            cp "$tmp" "$file"
            echo "  [OK] $rel"
        else
            echo "  [FAIL] $rel"
        fi
        rm -f "$tmp" "${tmp}.idsig"
    done

    # NOT deleting oat files - let runtime handle stale checksums

    umount "$MNT"
    rmdir "$MNT"

    # Convert back to sparse
    img2simg "$RAW" "$IMG"
    rm -f "$RAW"
}

sign_partition "$CUSTOM/system.img" "system"
sign_partition "$CUSTOM/product.img" "product"
sign_partition "$CUSTOM/vendor.img" "vendor"

echo ""
echo "Done."
