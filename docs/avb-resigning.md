# AVB Re-signing - Findings

## What Works

AVB (Android Verified Boot) re-signing is fully working. The E4810 uses AOSP test keys:

- **vbmeta**: AOSP testkey RSA4096 (SHA1: `2597c218aae470a130f61162feaae70afd97f011`)
- **system (chained)**: AOSP testkey RSA2048 (SHA1: `cdbb77177f731920bbe0a0f94f84d9038ae0617d`)
- **boot**: Algorithm NONE (hash only)
- **vendor/product**: Algorithm NONE, included directly in vbmeta

## A/B Slot Flashing - CRITICAL

The E4810 has A/B partition slots. **Must flash to BOTH slots** (`_a` and `_b`). Flashing only one slot causes the bootloader to detect a mismatch on the other slot and show "device is corrupt" (stuck, not dismissable).

```bash
for img in boot system vendor product vbmeta; do
    fastboot flash ${img}_a output/${img}.img
    fastboot flash ${img}_b output/${img}.img
done
```

The `output/flash_all.sh` script handles this automatically.

## vbmeta Format - CRITICAL

The vbmeta must be built WITHOUT:
- `--padding_size` - stock vbmeta is ~4KB, padding to 64KB may cause issues
- Explicit `--prop` flags - vendor/product images already embed security_patch props in their AVB footers; adding them again creates duplicates

Correct vbmeta build:
```bash
avbtool make_vbmeta_image \
    --output vbmeta.img \
    --key keys/vbmeta.pem \
    --algorithm SHA256_RSA4096 \
    --include_descriptors_from_image boot.img \
    --include_descriptors_from_image dtbo.img \
    --include_descriptors_from_image vendor.img \
    --include_descriptors_from_image product.img \
    --chain_partition system:2:keys/system.avbpubkey
```

## dm-verity Limitation

**Modifying files on ext4 images breaks dm-verity runtime verification.** This applies to ANY modification - even copying a file over itself with `cp`. The hashtree computed on the host Linux doesn't match what the Android device reads at runtime. This is an ext4 implementation difference between the host Linux kernel and Android 9.

Small metadata-only edits (like editing a small XML file in-place with Python) may work, but file copy operations (`cp`, `signapk.jar`) that reallocate blocks do not.

**Magisk boot is required** for modified partitions. Magisk's `magiskinit` handles dm-verity errors gracefully, allowing boot to continue. The AVB bootloader-level verification (vbmeta signature, chain of trust) remains fully enforced.

Without Magisk, modified partitions cause:
- "won't boot past Kyocera logo" (dm-verity fatal error during init)
- "boots to recovery" (system mount failure)

## Partition Modification Requirements

### Sparse Image Handling
Custom images from the device are Android sparse format. Scripts must:
1. Convert sparse → raw with `simg2img`
2. Erase AVB footer with `avbtool erase_footer`
3. Run `e2fsck` + `resize2fs` to fit ext4 within stock partition bounds
4. Add AVB hashtree footer with correct partition size
5. Convert back to sparse with `img2simg`

**Note:** The e2fsck/resize2fs step modifies the filesystem. This is acceptable when using Magisk boot (which handles dm-verity). Do NOT use e2fsck/resize2fs if targeting stock boot - the filesystem modifications cause dm-verity failures.

### FEC Must Be Enabled
Stock images have `FEC num roots: 2`. The `fec` binary must be in PATH when running avbtool.

### Security Patch Props
Stock vendor/product images embed security_patch props in their AVB footers. Do NOT add explicit `--prop` flags to vbmeta - the props are automatically included via `--include_descriptors_from_image`.

## Stock Partition Sizes

| Partition | Image Size (with footer) | Original Data Size | Flash Partition |
|-----------|-------------------------|-------------------|-----------------|
| boot | 33,554,432 | ~18,089,984 | 32 MB |
| system | 922,746,880 | 908,103,680 | ~880 MB |
| vendor | 419,430,400 | 412,729,344 | ~400 MB |
| product | 524,288,000 | 515,936,256 | ~500 MB |
| dtbo | 8,388,608 | 1,287,714 | 8 MB |
| vbmeta | ~4,096 | ~3,584 | 64 KB |

## Scripts

| Script | Purpose |
|--------|---------|
| `resign_boot.sh` | Add AVB hash footer to boot (Algorithm NONE) |
| `resign_system.sh` | AVB re-sign system (handles sparse/raw, resize2fs, SHA256_RSA2048, FEC) |
| `resign_product.sh` | AVB re-sign product (Algorithm NONE, FEC) |
| `resign_vendor.sh` | AVB re-sign vendor (Algorithm NONE, FEC) |
| `rebuild_vbmeta.sh` | Build vbmeta with all descriptors + system chain (no padding, no dup props) |
| `verify_chain.sh` | Verify entire AVB chain before flashing |

## Tools Required
- `avbtool.py` (in `tools/avb-tools/`)
- `e2fsck` and `resize2fs` (in `tools/android-bins/`)
- `fec` binary (in `tools/fec/`) - required for FEC generation
- `simg2img` / `img2simg` - system packages
