#!/bin/bash
# Resign ONLY android.uid.system APKs with apksigner v3-only
# Preserves ZIP structure so .odex files stay valid

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CUSTOM="$ROOT_DIR/firmware/custom"
KS="$ROOT_DIR/app_keystore/platform.jks"
KEY_PASS="${KEY_PASS:-changeit}"

SIGN_ARGS="--ks $KS --ks-key-alias platform --ks-pass pass:$KEY_PASS --key-pass pass:$KEY_PASS --v1-signing-enabled false --v2-signing-enabled false --v3-signing-enabled true"

sign_apk() {
    local apk="$1"
    local rel="$2"
    local tmp="/tmp/e4810_uid_sign.apk"

    cp "$apk" "$tmp"
    chmod 644 "$tmp"
    if apksigner sign $SIGN_ARGS "$tmp" 2>/dev/null; then
        cp "$tmp" "$apk"
        echo "  [OK] $rel"
    else
        echo "  [FAIL] $rel"
    fi
    rm -f "$tmp" "${tmp}.idsig"
}

process_partition() {
    local IMG="$1"
    local NAME="$2"
    shift 2
    local APKS=("$@")

    [ ! -f "$IMG" ] && echo "Skipping $NAME" && return

    echo ""
    echo "=== $NAME ==="

    local RAW="/tmp/e4810_${NAME}_raw.img"
    local MNT="/tmp/e4810_${NAME}_mnt"

    if file "$IMG" | grep -q "Android sparse"; then
        simg2img "$IMG" "$RAW"
    else
        cp "$IMG" "$RAW"
    fi
    python3 "$ROOT_DIR/tools/avb-tools/avbtool.py" erase_footer --image "$RAW" 2>/dev/null || true

    mkdir -p "$MNT"
    mount -o loop "$RAW" "$MNT"

    for apk_path in "${APKS[@]}"; do
        local full="$MNT${apk_path}"
        if [ -f "$full" ]; then
            sign_apk "$full" "$apk_path"
        else
            echo "  [MISS] $apk_path"
        fi
    done

    umount "$MNT"
    rmdir "$MNT"
    img2simg "$RAW" "$IMG"
    rm -f "$RAW"
}

# System android.uid.system APKs
SYSTEM_APKS=(
    "/system/app/WifiAutoActivate/WifiAutoActivate.apk"
    "/system/app/KeyChain/KeyChain.apk"
    "/system/app/KCHandleNv/KCHandleNv.apk"
    "/system/app/PcoStatusReceiver/PcoStatusReceiver.apk"
    "/system/app/DynamicDDSService/DynamicDDSService.apk"
    "/system/app/LabTest/LabTest.apk"
    "/system/app/KCLightsService/KCLightsService.apk"
    "/system/app/WallpaperBackup/WallpaperBackup.apk"
    "/system/framework/framework-res.apk"
    "/system/priv-app/FusedLocation/FusedLocation.apk"
    "/system/priv-app/SkyhookLocationProvider/SkyhookLocationProvider.apk"
    "/system/priv-app/SettingsProvider/SettingsProvider.apk"
    "/system/priv-app/Settings/Settings.apk"
    "/system/priv-app/SelfProvisioning/SelfProvisioning.apk"
    "/system/priv-app/kcTelecom/kcTelecom.apk"
    "/system/priv-app/CNEService/CNEService.apk"
    "/system/priv-app/com.qualcomm.location/com.qualcomm.location.apk"
    "/system/priv-app/InputDevices/InputDevices.apk"
    "/system/priv-app/VzwService/VzwService.apk"
    "/system/priv-app/SystemUI/SystemUI.apk"
)

PRODUCT_APKS=(
    "/priv-app/KcSettingsProvider/KcSettingsProvider.apk"
    "/priv-app/KcNfpSettings/KcNfpSettings.apk"
    "/priv-app/KcCustomizeKey/KcCustomizeKey.apk"
    "/priv-app/KcCellBroadcastReceiver/KcCellBroadcastReceiver.apk"
    "/priv-app/Diagnostic/Diagnostic.apk"
    "/priv-app/OEMSetupWizard/OEMSetupWizard.apk"
    "/priv-app/BatteryCareApp/BatteryCareApp.apk"
    "/priv-app/KcKittingApp/KcKittingApp.apk"
    "/app/kcPhoneService/kcPhoneService.apk"
    "/app/kcTelecommService/kcTelecommService.apk"
    "/app/EnterpriseActivate/EnterpriseActivate.apk"
    "/app/Ecomode/Ecomode.apk"
    "/app/CorpManager/CorpManager.apk"
)

VENDOR_APKS=(
    "/app/KErrService/KErrService.apk"
    "/app/PowerOffAlarm/PowerOffAlarm.apk"
    "/app/KdfsService/KdfsService.apk"
    "/app/ThermalMonitorService/ThermalMonitorService.apk"
)

process_partition "$CUSTOM/system.img" "system" "${SYSTEM_APKS[@]}"
process_partition "$CUSTOM/product.img" "product" "${PRODUCT_APKS[@]}"
process_partition "$CUSTOM/vendor.img" "vendor" "${VENDOR_APKS[@]}"

echo ""
echo "Done. Only android.uid.system APKs re-signed."
