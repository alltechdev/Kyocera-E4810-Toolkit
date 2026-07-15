#!/bin/bash
# Verify OTA update was applied correctly
# Compares partition hashes on device against source images in raw_images/

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATOR_DIR="$(dirname "$SCRIPT_DIR")"
RAW_DIR="$CREATOR_DIR/raw_images"

echo "=== Verifying OTA Update ==="

# Check which slot is active
SLOT=$(adb shell su -c "getprop ro.boot.slot_suffix" | tr -d '\r\n')
echo "Active slot: $SLOT"

# Check SELinux
SELINUX=$(adb shell su -c "getenforce" | tr -d '\r\n')
echo "SELinux: $SELINUX"
echo ""

PASS=0
FAIL=0
SKIP=0

for img in "$RAW_DIR"/*.img; do
    [ ! -f "$img" ] && continue
    part=$(basename "$img" .img)

    # Skip temp/intermediate files
    case "$part" in
        *_avb|*_old|*_new|*_bak) SKIP=$((SKIP+1)); continue ;;
    esac

    # Get expected hash and size
    expected=$(sha256sum "$img" | awk '{print $1}')
    size=$(stat -c%s "$img")
    blocks=$((size / 4096))

    # Get actual hash from device (active slot)
    device_part="/dev/block/by-name/${part}${SLOT}"

    # Check partition exists
    if ! adb shell su -c "test -e $device_part" 2>/dev/null; then
        echo "[SKIP] $part: partition ${part}${SLOT} not found"
        SKIP=$((SKIP+1))
        continue
    fi

    actual=$(adb shell su -c "dd if=$device_part bs=4096 count=$blocks 2>/dev/null | sha256sum" | awk '{print $1}')

    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $part ($((size/1024/1024))MB)"
        PASS=$((PASS+1))
    else
        echo "[FAIL] $part: hash mismatch"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        FAIL=$((FAIL+1))
    fi
done

echo ""
if [ $FAIL -eq 0 ] && [ $PASS -gt 0 ]; then
    echo "All $PASS partition(s) verified. OTA applied correctly."
else
    echo "$PASS passed, $FAIL failed, $SKIP skipped."
    [ $FAIL -gt 0 ] && exit 1
fi
