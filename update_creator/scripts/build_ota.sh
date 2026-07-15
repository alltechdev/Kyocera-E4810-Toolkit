#!/bin/bash
# Build a signed OTA update package from partition images in raw_images/
#
# Images must be prepared first with prepare_images.sh - raw format,
# WITH AVB footers intact, padded to partition size. Filenames must
# match partition names (product.img, vbmeta.img, etc.)
#
# Usage: ./scripts/build_ota.sh [partition1.img partition2.img ...]
# If no args, builds from all .img files in raw_images/

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATOR_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$CREATOR_DIR")"
OUTPUT="$CREATOR_DIR/output"
RAW_IMAGES="$CREATOR_DIR/raw_images"
CERTS="$ROOT_DIR/certs/ota"
SIGNAPK="$ROOT_DIR/ROM_resigner/signapk.jar"
SIGNAPK_LIB="$ROOT_DIR/ROM_resigner/Linux"

mkdir -p "$OUTPUT"

# Determine input images
if [ $# -gt 0 ]; then
    IMAGES=("$@")
else
    # Exclude temp files (*_avb, *_old, *_new, etc.)
    IMAGES=()
    for f in "$RAW_IMAGES"/*.img; do
        [ ! -f "$f" ] && continue
        base=$(basename "$f" .img)
        case "$base" in
            *_avb|*_old|*_new|*_bak) continue ;;
            *) IMAGES+=("$f") ;;
        esac
    done
fi

# Validate inputs
if [ ${#IMAGES[@]} -eq 0 ]; then
    echo "Error: No images found"
    echo "Usage: $0 [image1.img image2.img ...]"
    echo "Or run: ./scripts/prepare_images.sh <partitions>"
    exit 1
fi

echo "=== Building OTA Update ==="
echo "Images:"
TARGET_ARGS=()
for img in "${IMAGES[@]}"; do
    [ ! -f "$img" ] && echo "Error: $img not found" && exit 1
    base=$(basename "$img" .img)
    echo "  $base ($(du -h "$img" | cut -f1))"
    TARGET_ARGS+=("--target-image" "$img")
done

# Step 1: Generate unsigned payload
# CRITICAL: Use bz2 - Android 9's update_engine rejects xz options from payload_packer
echo ""
echo "=== Step 1: Generating payload (bzip2) ==="
"$CREATOR_DIR/payload_packer" \
    "${TARGET_ARGS[@]}" \
    --method bz2 \
    --output "$OUTPUT/payload.bin"

# Step 2: Sign the payload
echo ""
echo "=== Step 2: Signing payload ==="
python3 "$CREATOR_DIR/sign_payload.py" \
    "$OUTPUT/payload.bin" \
    "$OUTPUT/payload_signed.bin" \
    "$CERTS/payload.pem"

# Step 3: Build OTA ZIP
echo ""
echo "=== Step 3: Building OTA ZIP ==="
BUILD="$CREATOR_DIR/build"
rm -rf "$BUILD"
mkdir -p "$BUILD/META-INF/com/google/android"
echo 'ui_print("Applying update...");' > "$BUILD/META-INF/com/google/android/updater-script"
cp "$OUTPUT/payload_signed.bin" "$BUILD/payload.bin"
cp "$OUTPUT/payload_properties.txt" "$BUILD/payload_properties.txt"

# CRITICAL: payload.bin MUST be stored uncompressed (zip -0)
# update_engine reads it by offset - compression corrupts the data
cd "$BUILD"
zip -r "$OUTPUT/update_unsigned.zip" META-INF/ payload_properties.txt
zip -0 "$OUTPUT/update_unsigned.zip" payload.bin
cd "$CREATOR_DIR"

# Step 4: Sign the ZIP with OTA key
echo ""
echo "=== Step 4: Signing OTA ZIP ==="
java -Djava.library.path="$SIGNAPK_LIB" \
    -jar "$SIGNAPK" -w \
    "$CERTS/ota.x509.pem" "$CERTS/ota.pk8" \
    "$OUTPUT/update_unsigned.zip" "$OUTPUT/update.zip"

# Clean up
rm -rf "$BUILD" "$OUTPUT/update_unsigned.zip"

echo ""
echo "=== OTA Update Package Ready ==="
echo "Output: $OUTPUT/update.zip ($(du -h "$OUTPUT/update.zip" | cut -f1))"
echo ""
echo "Next: ./scripts/push_ota.sh"
