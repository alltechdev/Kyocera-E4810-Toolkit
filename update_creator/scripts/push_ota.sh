#!/bin/bash
# Push OTA update to device and apply via update_engine
# Usage: ./scripts/push_ota.sh [update.zip]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATOR_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT="$CREATOR_DIR/output"

OTA_ZIP="${1:-$OUTPUT/update.zip}"

if [ ! -f "$OTA_ZIP" ]; then
    echo "Error: $OTA_ZIP not found"
    echo "Usage: $0 [update.zip]"
    exit 1
fi

echo "=== Pushing OTA Update ==="
echo "File: $OTA_ZIP ($(du -h "$OTA_ZIP" | cut -f1))"

# Get payload offset and size within the ZIP
read -r OFFSET SIZE <<< $(python3 -c "
import zipfile, struct
with open('$OTA_ZIP', 'rb') as f:
    z = zipfile.ZipFile(f)
    for info in z.infolist():
        if info.filename == 'payload.bin':
            f.seek(info.header_offset)
            header = f.read(30)
            fname_len = struct.unpack('<H', header[26:28])[0]
            extra_len = struct.unpack('<H', header[28:30])[0]
            print(f'{info.header_offset + 30 + fname_len + extra_len} {info.file_size}')
")

PROPS_FILE="$OUTPUT/payload_properties.txt"
if [ ! -f "$PROPS_FILE" ]; then
    echo "Error: $PROPS_FILE not found"
    exit 1
fi

echo "Payload offset: $OFFSET"
echo "Payload size: $SIZE"
echo ""

# Push files to device
echo "Pushing OTA ZIP..."
adb push "$OTA_ZIP" /sdcard/update.zip

echo "Copying to /data/ota_package/..."
adb shell su -c "cp /sdcard/update.zip /data/ota_package/update.zip"
adb shell su -c "chown system:cache /data/ota_package/update.zip"

# Push properties file separately (shell heredocs strip base64 '=' padding)
echo "Pushing payload properties..."
adb push "$PROPS_FILE" /sdcard/payload_properties.txt
adb shell su -c "cp /sdcard/payload_properties.txt /data/ota_package/payload_properties.txt"

# Write apply script that reads headers from the properties file
# This avoids ALL shell quoting issues with base64 characters (+, =, /)
echo "Writing apply script..."
cat > /tmp/apply_ota.sh << LOCALEOF
#!/system/bin/sh
HEADERS=""
while IFS= read -r line; do
    if [ -z "\$HEADERS" ]; then
        HEADERS="\$line"
    else
        HEADERS="\${HEADERS}
\${line}"
    fi
done < /data/ota_package/payload_properties.txt

update_engine_client \\
  --payload=file:///data/ota_package/update.zip \\
  --offset=$OFFSET \\
  --size=$SIZE \\
  --headers="\$HEADERS" \\
  --update \\
  --follow
LOCALEOF

adb push /tmp/apply_ota.sh /sdcard/apply_ota.sh
adb shell su -c "cp /sdcard/apply_ota.sh /data/local/tmp/apply_ota.sh"
adb shell su -c "chmod 755 /data/local/tmp/apply_ota.sh"
rm -f /tmp/apply_ota.sh

# Reset update_engine state
echo "Resetting update_engine..."
adb shell su -c "update_engine_client --reset_status"

# Apply
echo ""
echo "=== Applying OTA Update ==="
adb shell su -c "/data/local/tmp/apply_ota.sh"
RESULT=$?

if [ $RESULT -eq 0 ]; then
    echo ""
    echo "=== Update Applied Successfully ==="
    echo "Reboot to activate the new slot: adb reboot"
else
    echo ""
    echo "=== Update Failed (exit code $RESULT) ==="
    echo "Check logs:"
    echo "  adb shell su -c 'ls -lt /data/misc/update_engine_log/'"
    echo "  adb shell su -c 'tail -30 /data/misc/update_engine_log/<latest>'"
    exit 1
fi
