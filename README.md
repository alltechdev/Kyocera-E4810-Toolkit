# Disclaimer

I WILL NOT BE HELD RESPONSIBLE FOR BRICKED DEVICES OR YOUR INSANITY WHILE YOU GO THROUGH THIS PROCESS. DO NOT ASK ME TO UNBRICK YOUR DEVICE. I WILL SAY NO. MINIMAL SUPPORT WILL BE GIVEN IN GENERAL FOR THE CONTENTS OF THIS REPO.

# Kyocera E4810 Toolkit

Root Kyocera E4810 with Magisk and re-sign all system APKs with custom keys, while maintaining locked bootloader and AVB chain integrity.

**Requires Magisk-patched boot image** - stock boot cannot boot modified partitions due to dm-verity runtime verification (see [docs/dm-verity-issue.md](docs/dm-verity-issue.md)). Magisk boot is actually MORE secure than disabling dm-verity - see docs for details.

## Prerequisites

- Linux system with: `openssl`, `keytool`, `python3`, `java`, `simg2img`, `img2simg`
- Python cryptography module: `pip3 install cryptography`
- Magisk-patched boot image for your device
- Stock firmware partition images (system.img, product.img, vendor.img, dtbo.img)

### Obtaining Stock Firmware

Download stock E4810 firmware from Kyocera:
http://perpetuity.kyocera.co.jp/pctool/kcfirmware/binfile66.bin

The file is a ZIP archive. Extract it to get the partition images:
```bash
unzip binfile66.bin -d binfile66/
# Contains: system.img, vendor.img, product.img, boot.img, dtbo.img, vbmeta.img
```

Place images in the repo:
```bash
cp binfile66/*.img firmware/stock/
```

Then copy to `firmware/custom/` for modification:
```bash
cp firmware/stock/system.img firmware/stock/vendor.img firmware/stock/product.img firmware/custom/
```

## Setup

### 1. Configure Your Keys

Edit `keys.conf` to customize your signing keys:

```
# Each line: SEINFO|CN|ORG|COUNTRY
platform|mycompany-platform|My Company|US
media|mycompany-media|My Company|US
verizon|mycompany-verizon|My Company|US
...
```

**CRITICAL:** Each seinfo type MUST have a unique CN. Using the same CN for multiple entries causes Android to reject all policies.

### 2. Generate Keys

```bash
./scripts/generate_keys.sh
```

Or set password via environment:
```bash
KEY_PASS=mysecretpassword ./scripts/generate_keys.sh
```

This generates:
- `certs/aosp/*.pk8, *.x509.pem` - APK signing keys (EC P-256)
- `app_keystore/{platform,media,verizon}.jks` - JKS keystores
- `certs/ota/*` - OTA signing keys (RSA 2048)
- `keys/system.avbpubkey` - extracted from included vbmeta_system.pem

### AVB Keys (Included)

AVB keys (`keys/vbmeta.pem`, `keys/vbmeta_system.pem`) are **included** in the repo - these are AOSP test keys matching the E4810's root of trust. They cannot be randomly generated. See `SECURITY.md` for details.

## Why This Works

E4810 (Qualcomm-based) uses AOSP test keys for AVB signing:

| Partition | Key | SHA1 |
|-----------|-----|------|
| vbmeta | AOSP testkey RSA4096 | `2597c218aae470a130f61162feaae70afd97f011` |
| system (chained) | AOSP testkey RSA2048 | `cdbb77177f731920bbe0a0f94f84d9038ae0617d` |

## AVB Structure

```
vbmeta.img (RSA4096, AOSP testkey)
├── Hash descriptor: boot (Algorithm NONE - hash only, no signature)
├── Hash descriptor: dtbo
├── Hashtree descriptor: vendor (FEC enabled)
├── Hashtree descriptor: product (FEC enabled)
└── Chain partition: system → signed separately with AOSP testkey
```

## APK Re-signing

All system APKs can be re-signed with custom keys using the included ROM_resigner tool. This replaces Kyocera's platform signing keys across system, product, and vendor partitions.

**CRITICAL:** Each seinfo type in `mac_permissions.xml` MUST use a unique signing key. Using the same key for multiple seinfo entries causes Android's `PolicyComparator` to reject all policies, crashing every app. See [docs/selinux-investigation.md](docs/selinux-investigation.md) for details.

### Signing Keys (EC P-256)

| Key | seinfo | Usage |
|-----|--------|-------|
| `platform.pk8` | platform | System apps, framework-res, Settings, SystemUI |
| `media.pk8` | media | MediaProvider, DownloadProvider |
| `verizon.pk8` | verizon | DMAT_Stub (com.verizon.obdm) |

Keys are generated to `certs/aosp/` and `ROM_resigner/AOSP_security/` by `generate_keys.sh`.

### Quick Start (APK Re-signing)

```bash
# 1. Mount partitions
for part in system product vendor; do
    simg2img firmware/custom/${part}.img /tmp/e4810_${part}.img
    python3 tools/avb-tools/avbtool.py erase_footer --image /tmp/e4810_${part}.img
    mkdir -p /tmp/e4810_${part}_mnt
    sudo mount -o loop /tmp/e4810_${part}.img /tmp/e4810_${part}_mnt
done

# 2. Resign APKs (uses AOSP_security keys by default)
sudo python3 ROM_resigner/resign.py \
    /tmp/e4810_system_mnt/system,/tmp/e4810_product_mnt,/tmp/e4810_vendor_mnt

# 3. Unmount and convert to sparse
for part in system product vendor; do
    sudo umount /tmp/e4810_${part}_mnt
    img2simg /tmp/e4810_${part}.img firmware/custom/${part}.img
done

# 4. AVB resign + rebuild vbmeta
cp /path/to/magisk_patched_boot.img output/boot.img
./scripts/resign_system.sh firmware/custom/system.img
./scripts/resign_product.sh firmware/custom/product.img
./scripts/resign_vendor.sh firmware/custom/vendor.img
./scripts/rebuild_vbmeta.sh
./scripts/verify_chain.sh

# 5. Flash BOTH A/B slots
./output/flash_all.sh
```

## A/B Slot Flashing - CRITICAL

The E4810 has A/B partition slots. **Must flash to BOTH slots** (`_a` and `_b`). Flashing only one slot causes the bootloader to show "device is corrupt" and refuse to boot.

The `output/flash_all.sh` script handles this automatically.

## System / Product / Vendor Modification

**IMPORTANT:** Do NOT recreate the filesystem. Modify files **in place** to preserve Android ext4 features (shared_blocks, orphan_file). Recreating the filesystem causes RED STATE.

Input can be raw ext4 or Android sparse format - the resign scripts handle both automatically.

### Resign and rebuild

```bash
./scripts/resign_system.sh firmware/custom/system.img
./scripts/resign_product.sh firmware/custom/product.img
./scripts/resign_vendor.sh firmware/custom/vendor.img
./scripts/rebuild_vbmeta.sh
./scripts/verify_chain.sh
```

The resign scripts will:
- Convert sparse to raw if needed
- Run `e2fsck` and `resize2fs` to fit ext4 within stock partition bounds
- Add AVB hashtree footer with FEC (matching stock)
- Convert back to sparse automatically

## Scripts

| Script | Purpose |
|--------|---------|
| `resign_boot.sh` | Add AVB hash footer to Magisk-patched boot (Algorithm NONE) |
| `resign_system.sh` | AVB re-sign system (handles sparse/raw, resize2fs, SHA256_RSA2048, FEC) |
| `resign_product.sh` | AVB re-sign product (Algorithm NONE, FEC) |
| `resign_vendor.sh` | AVB re-sign vendor (Algorithm NONE, FEC) |
| `rebuild_vbmeta.sh` | Build vbmeta with all descriptors + system chain (no padding, no dup props) |
| `verify_chain.sh` | Verify entire AVB chain before flashing |
| `ROM_resigner/resign.py` | Re-sign all APKs + update mac_permissions |
| `generate_keys.sh` | Generate APK/OTA signing keys from keys.conf |
| `resign_apks.sh` | Alternative: resign APKs using apksigner + JKS keystore |
| `resign_all_apks.sh` | Alternative: resign APKs with signapk.jar |
| `resign_system_uid.sh` | Resign only android.uid.system APKs (preserves .odex) |

## OTA Updates

For creating custom OTA update packages that the device's `update_engine` will accept, see `update_creator/README.md`.

**Important:** Use `--method bz2` compression only. Android 9's `update_engine` rejects XZ compression.

## Directory Structure

```
Kyocera-E4810-Toolkit/
├── keys/                      # AVB signing keys (included AOSP testkeys)
│   ├── vbmeta.pem             # RSA4096
│   ├── vbmeta_system.pem      # RSA2048
│   └── system.avbpubkey       # Public key for chain (generated by generate_keys.sh)
├── certs/                     # Signing certs
│   ├── aosp/                  # APK signing keys (.x509.pem + .pk8, generated)
│   └── ota/                   # OTA signing keys (generated)
├── app_keystore/              # JKS keystores for apksigner (generated)
├── ROM_resigner/              # APK re-signing tool (ybtag fork, modified)
│   ├── resign.py              # Main script
│   ├── signapk.jar            # AOSP signing tool
│   ├── AOSP_security/         # Default signing keys (generated)
│   └── Linux/                 # Native libs for signapk
├── update_creator/            # OTA update package builder
├── firmware/
│   ├── stock/                 # Original firmware images
│   └── custom/                # Modified images
├── output/                    # Ready-to-flash images
│   └── flash_all.sh           # Flash all partitions to both A/B slots
├── scripts/                   # AVB resign + key generation scripts
├── tools/                     # avb-tools, android-bins, fec, etc.
└── docs/                      # Investigation findings
```

## Resign a Single APK

```bash
java -Djava.library.path=ROM_resigner/Linux \
    -jar ROM_resigner/signapk.jar \
    --min-sdk-version 24 \
    certs/aosp/platform.x509.pem certs/aosp/platform.pk8 \
    input.apk output.apk
```

Use `platform` key for system apps, `media` for media apps, `verizon` for Verizon apps.

## Verification Checklist

After running `verify_chain.sh`, confirm:

- [x] vbmeta key: `2597c218aae470a130f61162feaae70afd97f011`
- [x] system chain key: `cdbb77177f731920bbe0a0f94f84d9038ae0617d`
- [x] boot Algorithm: NONE
- [x] boot hash in vbmeta matches boot.img footer
- [x] All partition hashes match (stock or custom)
- [x] No duplicate certs in mac_permissions across system + vendor
- [x] FEC enabled on system, vendor, product
- [x] vbmeta size ~3-4KB (no padding)
- [x] SELinux enforcing, 0 setcontext crashes
- [x] Dev options working

## Documentation

- [docs/full-process.md](docs/full-process.md) - Complete step-by-step guide
- [docs/apk-resigning.md](docs/apk-resigning.md) - APK re-signing details
- [docs/avb-resigning.md](docs/avb-resigning.md) - AVB chain signing details
- [docs/selinux-investigation.md](docs/selinux-investigation.md) - SELinux/mac_permissions analysis
- [docs/dm-verity-issue.md](docs/dm-verity-issue.md) - Why Magisk boot is required
- [docs/directory-layout.md](docs/directory-layout.md) - Repository structure reference

## Acknowledgments

- [ybtag/ROM_resigner](https://github.com/ybtag/ROM_resigner) - APK re-signing tool (modified fork in `ROM_resigner/`)
- AOSP AVB tools - `platform/external/avb` (in `tools/avb-tools/`)
- [rhythmcache/payload_packer](https://github.com/rhythmcache/payload_packer) - OTA payload generator (in `update_creator/`)
- AOSP - signapk.jar, e2fsck, resize2fs, fec tools
