# Full Process: Stock Firmware to Resigned APKs

Complete step-by-step guide to go from stock Kyocera E4810 firmware to a fully working build with all APKs re-signed with custom keys.

## Prerequisites

- Stock firmware dump (e.g., `binfile66STOCK/` with system.img, vendor.img, product.img, boot.img, dtbo.img)
- Magisk-patched boot image - install Magisk app on another Android device, select "Install" > "Select and Patch a File", choose stock boot.img, get magisk_patched_*.img
- This repository cloned with all tools
- `simg2img`, `img2simg` installed (system packages)
- `7z` installed (for ROM_resigner cert extraction)
- Java runtime (for signapk.jar)

## Step 1: Prepare Working Directory

```bash
cd <repo-root>

# Copy stock images to firmware/custom/
cp /path/to/stock/system.img firmware/custom/system.img
cp /path/to/stock/product.img firmware/custom/product.img
cp /path/to/stock/vendor.img firmware/custom/vendor.img

# Stock dtbo goes to firmware/stock/ (used by rebuild_vbmeta.sh)
cp /path/to/stock/dtbo.img firmware/stock/dtbo.img
```

## Step 2: Make Filesystem Modifications (Optional)

If you need to remove apps, edit configs, etc. - do it BEFORE APK re-signing.

```bash
# Convert sparse to raw + strip AVB footer
for part in system product vendor; do
    simg2img firmware/custom/${part}.img /tmp/e4810_${part}.img
    python3 tools/avb-tools/avbtool.py erase_footer --image /tmp/e4810_${part}.img 2>/dev/null || true
    mkdir -p /tmp/e4810_${part}_mnt
    sudo mount -o loop /tmp/e4810_${part}.img /tmp/e4810_${part}_mnt
done

# Make your modifications (remove apps, edit configs, etc.)
# Example: sudo rm /tmp/e4810_system_mnt/system/bin/ktfilter

# Unmount + convert back to sparse
for part in system product vendor; do
    sudo umount /tmp/e4810_${part}_mnt
    rmdir /tmp/e4810_${part}_mnt
    img2simg /tmp/e4810_${part}.img firmware/custom/${part}.img
    rm -f /tmp/e4810_${part}.img
done

# Save a snapshot BEFORE APK re-signing (recommended)
mkdir -p firmware/backup
cp firmware/custom/system.img firmware/backup/system.img
cp firmware/custom/product.img firmware/backup/product.img
cp firmware/custom/vendor.img firmware/backup/vendor.img
```

## Step 3: Re-sign APKs

```bash
# Mount all three partitions
for part in system product vendor; do
    simg2img firmware/custom/${part}.img /tmp/e4810_${part}.img
    python3 tools/avb-tools/avbtool.py erase_footer --image /tmp/e4810_${part}.img 2>/dev/null || true
    mkdir -p /tmp/e4810_${part}_mnt
    sudo mount -o loop /tmp/e4810_${part}.img /tmp/e4810_${part}_mnt
done

# Run ROM_resigner (single run only - do NOT run twice)
sudo python3 ROM_resigner/resign.py \
    /tmp/e4810_system_mnt/system,/tmp/e4810_product_mnt,/tmp/e4810_vendor_mnt \
    ROM_resigner/AOSP_security

# Verify output:
# - "X signed as platform/media/verizon" messages
# - "No duplicate certs across mac_permissions files - safe."
# - No "failed" messages

# Unmount + convert to sparse
for part in system product vendor; do
    sudo sync
    sudo umount /tmp/e4810_${part}_mnt
    rmdir /tmp/e4810_${part}_mnt 2>/dev/null
    img2simg /tmp/e4810_${part}.img firmware/custom/${part}.img
    rm -f /tmp/e4810_${part}.img
done
sudo losetup -D
```

## Step 4: AVB Re-sign

```bash
# Copy Magisk-patched boot to output
cp /path/to/boot(1).img output/boot.img

# AVB resign all partitions
./scripts/resign_system.sh firmware/custom/system.img
./scripts/resign_product.sh firmware/custom/product.img
./scripts/resign_vendor.sh firmware/custom/vendor.img

# Rebuild vbmeta (no padding, no duplicate props)
./scripts/rebuild_vbmeta.sh

# Verify chain
./scripts/verify_chain.sh
# Must show "All checks passed!"
```

## Step 5: Flash

```bash
# Device must be in fastboot mode
# Flash ALL partitions to BOTH A/B slots
./output/flash_all.sh

# Or manually:
for img in boot system vendor product vbmeta; do
    fastboot flash ${img}_a output/${img}.img
    fastboot flash ${img}_b output/${img}.img
done
fastboot erase chkcode
fastboot erase userdata   # Factory reset required after APK re-signing
```

## Step 6: First Boot

1. Device boots (first boot is slow - package cache rebuild)
2. Complete setup wizard
3. Install Magisk APK: `adb install /path/to/Magisk.apk`
4. Open Magisk app, grant su when prompted

## Step 7: Verify

```bash
# Check root
adb shell su -c id
# Expected: uid=0(root)

# Check SELinux
adb shell su -c getenforce
# Expected: Enforcing

# Check for SELinux crashes
adb shell su -c "dumpsys dropbox --print 2>/dev/null | grep -c 'selinux_android_setcontext'"
# Expected: 0

# Check APK signatures
adb shell su -c "cp /system/priv-app/Settings/Settings.apk /data/local/tmp/s.apk"
adb pull /data/local/tmp/s.apk /tmp/s.apk
apksigner verify --print-certs /tmp/s.apk
# Expected: CN=example-platform (your key)
```

## Resign a Single APK Later

```bash
# Use platform key for system/priv-app apps
java -Djava.library.path=ROM_resigner/Linux \
    -jar ROM_resigner/signapk.jar \
    --min-sdk-version 24 \
    certs/aosp/platform.x509.pem certs/aosp/platform.pk8 \
    input.apk output.apk

# Use media key for MediaProvider/DownloadProvider
# Use verizon key for Verizon apps
# Install as update:
adb install -r output.apk
```

## Important Rules

1. **Never run e2fsck/resize2fs** if targeting stock boot (breaks dm-verity). With Magisk boot, the scripts handle this and it works.
2. **Never run ROM_resigner twice** on the same mounted images - double-signing corrupts APKs.
3. **Always flash BOTH A/B slots** - single slot causes "device is corrupt."
4. **Factory reset required** after APK re-signing - stale package database causes crashes.
5. **Each seinfo type needs a unique key** - duplicate certs cause PolicyComparator to reject all policies.
6. **Magisk boot required** - stock boot cannot boot modified partitions due to dm-verity runtime failure.
7. **Save backup before re-signing** - copy images to firmware/backup/ first, since re-signing can't be undone.
