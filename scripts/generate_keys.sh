#!/bin/bash
# Generate signing keys for Kyocera-E4810-Toolkit
# Configure keys in keys.conf before running
#
# NOTE: AVB keys (vbmeta.pem, vbmeta_system.pem) are INCLUDED in the repo.
# These are AOSP test keys matching the E4810's root of trust.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$ROOT_DIR/keys.conf"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: keys.conf not found"
    echo "Copy keys.conf.example to keys.conf and customize it"
    exit 1
fi

# Check for cryptography module
if ! python3 -c "import cryptography" 2>/dev/null; then
    echo "ERROR: Python cryptography module required"
    echo "Install with: pip3 install cryptography"
    exit 1
fi

# Read config
KEY_PASS="${KEY_PASS:-$(grep '^KEY_PASS=' "$CONFIG" | cut -d= -f2)}"
KEY_PASS="${KEY_PASS:-changeit}"
VALIDITY_DAYS="$(grep '^VALIDITY_DAYS=' "$CONFIG" | cut -d= -f2)"
VALIDITY_DAYS="${VALIDITY_DAYS:-10000}"

echo "=== Checking AVB Keys ==="
if [ ! -f "$ROOT_DIR/keys/vbmeta.pem" ] || [ ! -f "$ROOT_DIR/keys/vbmeta_system.pem" ]; then
    echo "ERROR: AVB keys missing from keys/ directory"
    exit 1
fi
echo "AVB keys present"

echo "Extracting system.avbpubkey..."
python3 "$ROOT_DIR/tools/avb-tools/avbtool.py" extract_public_key \
    --key "$ROOT_DIR/keys/vbmeta_system.pem" \
    --output "$ROOT_DIR/keys/system.avbpubkey"

echo "=== Generating APK Signing Keys ==="
mkdir -p "$ROOT_DIR/certs/aosp"
mkdir -p "$ROOT_DIR/ROM_resigner/AOSP_security"
mkdir -p "$ROOT_DIR/app_keystore"

# Parse seinfo keys from config
grep -E '^(platform|media|verizon|shared|releasekey|networkstack|ssgapp|sysmonapp)\|' "$CONFIG" | while IFS='|' read -r seinfo cn org country; do
    echo "  $seinfo: CN=$cn, O=$org, C=$country"
    SUBJ="/C=$country/O=$org/CN=$cn"

    # Generate EC P-256 key in compact 67-byte PKCS#8 format (matches original)
    python3 "$SCRIPT_DIR/gen_compact_pk8.py" "$ROOT_DIR/certs/aosp/${seinfo}.pk8"
    PEM_FILE="$ROOT_DIR/certs/aosp/${seinfo}.pem"

    # Generate X.509 certificate
    openssl req -new -x509 -key "$PEM_FILE" \
        -out "$ROOT_DIR/certs/aosp/${seinfo}.x509.pem" \
        -days "$VALIDITY_DAYS" -subj "$SUBJ" 2>/dev/null

    # Generate JKS for platform/media/verizon
    if [ "$seinfo" = "platform" ] || [ "$seinfo" = "media" ] || [ "$seinfo" = "verizon" ]; then
        rm -f "$ROOT_DIR/app_keystore/${seinfo}.jks"
        openssl req -new -x509 -key "$PEM_FILE" \
            -out "/tmp/${seinfo}_jks.crt" -days "$VALIDITY_DAYS" -subj "$SUBJ" 2>/dev/null
        openssl pkcs12 -export -in "/tmp/${seinfo}_jks.crt" -inkey "$PEM_FILE" \
            -out "/tmp/${seinfo}.p12" -name "$seinfo" -passout "pass:$KEY_PASS" 2>/dev/null
        keytool -importkeystore -srckeystore "/tmp/${seinfo}.p12" -srcstoretype PKCS12 \
            -srcstorepass "$KEY_PASS" -destkeystore "$ROOT_DIR/app_keystore/${seinfo}.jks" \
            -deststoretype JKS -deststorepass "$KEY_PASS" -destkeypass "$KEY_PASS" \
            -srcalias "$seinfo" -destalias "$seinfo" 2>/dev/null
        rm -f "/tmp/${seinfo}_jks.crt" "/tmp/${seinfo}.p12"
    fi

    # Clean up temp PEM
    rm -f "$PEM_FILE"
done

# Copy to ROM_resigner/AOSP_security
cp "$ROOT_DIR/certs/aosp/"*.pk8 "$ROOT_DIR/ROM_resigner/AOSP_security/"
cp "$ROOT_DIR/certs/aosp/"*.x509.pem "$ROOT_DIR/ROM_resigner/AOSP_security/"

echo "=== Generating OTA Keys ==="
mkdir -p "$ROOT_DIR/certs/ota"
OTA_LINE="$(grep '^ota|' "$CONFIG")"
if [ -n "$OTA_LINE" ]; then
    IFS='|' read -r _ cn org country <<< "$OTA_LINE"
else
    cn="mykey-ota"; org="MyOrg"; country="US"
fi
SUBJ="/C=$country/O=$org/CN=$cn"

openssl genrsa -out "$ROOT_DIR/certs/ota/payload.pem" 2048 2>/dev/null
openssl rsa -in "$ROOT_DIR/certs/ota/payload.pem" -pubout \
    -out "$ROOT_DIR/certs/ota/payload.pub.pem" 2>/dev/null
openssl genrsa -out "$ROOT_DIR/certs/ota/ota.pem" 2048 2>/dev/null
openssl pkcs8 -topk8 -nocrypt -in "$ROOT_DIR/certs/ota/ota.pem" \
    -out "$ROOT_DIR/certs/ota/ota.pk8" -outform DER
openssl req -new -x509 -key "$ROOT_DIR/certs/ota/ota.pem" \
    -out "$ROOT_DIR/certs/ota/ota.x509.pem" \
    -days "$VALIDITY_DAYS" -subj "$SUBJ" 2>/dev/null

# Create otacerts.zip (certificate bundle for system image)
# Must use exact path structure that Android expects
mkdir -p /tmp/otacerts_tmp/vendor/kyocera/device/signing_key/android_key/sign_key
cp "$ROOT_DIR/certs/ota/ota.x509.pem" /tmp/otacerts_tmp/vendor/kyocera/device/signing_key/android_key/sign_key/releasekey.x509.pem
cd /tmp/otacerts_tmp
zip -D "$ROOT_DIR/certs/ota/otacerts.zip" vendor/kyocera/device/signing_key/android_key/sign_key/releasekey.x509.pem 2>/dev/null
cd "$ROOT_DIR"
rm -rf /tmp/otacerts_tmp

echo ""
echo "=== Done ==="
echo "Generated from keys.conf with password: $KEY_PASS"
