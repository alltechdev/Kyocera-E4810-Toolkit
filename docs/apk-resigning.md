# APK Re-signing - Final Working Solution

## Summary

Successfully replaced Kyocera platform signing keys with custom EC keys on the E4810 (Android 9). 107+ APKs re-signed across system, product, and vendor partitions. Device boots with SELinux enforcing, zero setcontext crashes, dev options working.

**Requires Magisk boot** - stock unrooted boot cannot boot modified partitions due to dm-verity runtime verification failure (see `docs/dm-verity-issue.md`).

## Working Tool Chain

### ROM_resigner (ybtag fork, modified)
Located at `./ROM_resigner/`

Key modifications from upstream:
1. **v3 APK signing block fallback** - extracts certs from v3 signing block for APKs without v1 signatures (META-INF/CERT.EC). Recovered 8 additional APKs.
2. **Fixed mac_permissions rewrite** - replaced `fileinput` + `print(end=' ')` with clean `read()/write()`. Original added trailing spaces that corrupted cert hex.
3. **Duplicate cert detection** - warns if same cert appears in multiple mac_permissions entries.
4. **Default keys path** - defaults to `AOSP_security/` in script directory.
5. **ADB flag** - pass `adb` as third argument to enable ADB props.
6. **`--min-sdk-version 24`** - required for EC key signing with signapk.jar.

### Usage
```bash
# Mount partitions
for part in system product vendor; do
    simg2img firmware/custom/${part}.img /tmp/e4810_${part}.img
    avbtool erase_footer --image /tmp/e4810_${part}.img
    sudo mount -o loop /tmp/e4810_${part}.img /tmp/e4810_${part}_mnt
done

# Resign APKs (uses AOSP_security keys by default)
sudo python3 ROM_resigner/resign.py \
    /tmp/e4810_system_mnt/system,/tmp/e4810_product_mnt,/tmp/e4810_vendor_mnt

# Unmount + sparse
for part in system product vendor; do
    sudo umount /tmp/e4810_${part}_mnt
    img2simg /tmp/e4810_${part}.img firmware/custom/${part}.img
done

# AVB resign (uses scripts/)
./scripts/resign_system.sh firmware/custom/system.img
./scripts/resign_product.sh firmware/custom/product.img
./scripts/resign_vendor.sh firmware/custom/vendor.img
cp /path/to/magisk_boot.img output/boot.img
./scripts/rebuild_vbmeta.sh
./scripts/verify_chain.sh

# Flash both slots
./output/flash_all.sh
```

## Key Architecture - CRITICAL

### Unique Keys Per seinfo Type
Each seinfo type in `mac_permissions.xml` MUST have a **unique signing key**. Using the same key for multiple seinfo entries causes Android's `PolicyComparator` to detect duplicates and reject ALL policies.

| Key | seinfo | CN | Usage |
|-----|--------|-----|-------|
| EC #1 | platform | example-platform | System apps, framework-res, Settings, SystemUI |
| EC #2 | media | example-media | MediaProvider, DownloadProvider |
| EC #3 | verizon | example-verizon | DMAT_Stub (com.verizon.obdm) |

Keys stored in `certs/aosp/` and `ROM_resigner/AOSP_security/`.

### PolicyComparator Duplicate Detection
Decompiled from `services.vdex` → `SELinuxMMAC.java`:

```java
// Compares certs across ALL mac_permissions files (system + vendor)
if (p1.mCerts.equals(p2.mCerts) && p1.hasGlobalSeinfo()) {
    duplicateFound = true;  // REJECTS ALL POLICIES
}
```

When all policies are rejected, every app gets `seinfo=default` → `selinux_android_setcontext()` fails → all apps crash.

### Signing Results
| Category | Count | Key |
|----------|-------|-----|
| Platform apps | ~85 | platform |
| Media apps | 4 | media |
| Verizon apps | 1 | verizon |
| Unknown (kept original) | ~37 | Not re-signed |
| JARs (no signature) | ~120 | Not signed |
| **Total re-signed** | **107+** | |

## Verified On Device
```
Root:               uid=0 (Magisk)
SELinux:            Enforcing
setcontext crashes: 0
Dev options:        Working
ADB dialog:         Working
Settings:           CN=example-platform (platform key)
SystemUI:           CN=example-platform (platform key)
framework-res:      CN=example-platform (platform key)
MediaProvider:      CN=example-media (media key)
DMAT_Stub:          CN=example-verizon (verizon key)
mac_permissions:    2 unique certs, no duplicates
vbmeta:             3392 bytes, no padding, no dup props
```
