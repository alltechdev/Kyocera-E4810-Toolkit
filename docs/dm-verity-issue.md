# dm-verity Runtime Verification Issue

## The Problem

When files are modified on ext4 system/vendor/product images (mounted on a Linux host), the dm-verity runtime block-level verification fails on the device, even though:
- The AVB hashtree is recomputed after modifications
- `avbtool verify_image` passes on the host
- The vbmeta chain verifies correctly
- File contexts, ext4 features, and sepolicy are all identical to stock

## Evidence

### What boots with stock (unrooted) boot:
- Full stock images (no modifications) [OK]
- Stock images + our rebuilt vbmeta (no image changes) [OK]
- Stock images + single small XML edit (mac_permissions, in-place with Python) [OK]

### What does NOT boot with stock boot:
- Any image where a file was copied with `cp` (even same content over itself) [FAIL]
- Any image with APK re-signing (signapk.jar modifies files) [FAIL]
- Images processed through e2fsck/resize2fs [FAIL]

### What boots with Magisk boot (boot(1).img):
- All of the above, including full APK re-signing [OK]

## Root Cause Theory

The ext4 filesystem on the Linux host and Android 9's init handle block-level data differently. When a file is modified via `cp` or `signapk.jar`:
1. The file is truncated (data blocks freed)
2. New data is written (blocks allocated, possibly at different locations)
3. ext4 metadata changes (block bitmaps, inode tables, extent trees)
4. On unmount, all changes are flushed

The hashtree is computed from the raw image AFTER unmount. The device then:
1. Reads the raw blocks from flash
2. Computes hashes
3. Compares against the hashtree

Something between steps causes a mismatch. Possible causes:
- ext4 delayed allocation metadata not fully resolved on host umount
- Block allocation patterns differ between host Linux kernel and Android 9
- Sparse image conversion (img2simg/simg2img) introduces subtle differences
- The host ext4 driver writes metadata differently than Android expects

Small in-place edits (like Python modifying a few bytes of an XML file) work because they don't trigger block reallocation - the same physical blocks are modified in-place.

## What We Tried

| Approach | Result |
|----------|--------|
| Recompute hashtree after modifications | Fails |
| Remove ext4 journal before hashtree | Fails |
| Use `dd` for in-place overwrite | Fails |
| Skip e2fsck/resize2fs | Fails |
| Add kernel cmdline descriptors to AVB footer | Boots but still fails dm-verity |
| Inject Magisk-patched sepolicy into vendor | Fails |
| Set `--set_hashtree_disabled_flag` in vbmeta | Boots (dm-verity skipped) |
| Use Magisk boot (boot(1).img) | Boots (dm-verity errors non-fatal) |

## How Magisk Makes It Work

Magisk's `magiskinit` replaces the stock init binary in the boot ramdisk. During early boot, magiskinit:
1. Patches the SELinux sepolicy at runtime (adds rules for Magisk domains)
2. Handles dm-verity in a way that makes verification errors non-fatal
3. Then exec's the original init

**Important:** The compiled sepolicy on disk is identical between stock and our build (verified by md5). Magisk's sepolicy patches are applied in-memory at runtime and are primarily for Magisk's own functionality (su, modules, etc.). The dm-verity handling is separate from sepolicy.

**What is NOT affected by this issue:**
- AVB bootloader verification (vbmeta signature checked, chain of trust enforced)
- Boot image hash verification
- Partition authentication (descriptors verified against vbmeta)

**What IS affected:**
- Runtime block-level hashtree verification during system/vendor/product mount

## Security Implications

The AVB chain of trust is fully intact:
- Nobody can flash arbitrary images without the RSA4096 vbmeta key
- The vbmeta signature is verified by the bootloader before any partition is loaded
- Boot image hash is verified against vbmeta
- System chain signature is verified against AOSP testkey

The dm-verity runtime check (which fails) would normally detect block-level tampering after flashing. With Magisk handling it non-fatally, this check is effectively bypassed. This is the same security model as any Magisk-rooted device.

## Why Magisk Boot Is More Secure Than Disabled dm-verity

There are two ways to boot modified partitions:

### Option A: `--set_hashtree_disabled_flag` in vbmeta
- Explicitly tells the bootloader to skip ALL hashtree verification
- dm-verity does not run at all
- Any block-level modification goes undetected
- Wider attack surface - if flash storage is tampered with post-flash, nothing catches it

### Option B: Magisk boot (current approach)
- dm-verity IS set up and runs
- Magisk's init handles verification errors non-fatal (continues boot instead of failing)
- dm-verity still detects modifications - it just doesn't abort
- AVB bootloader verification fully enforced (vbmeta signature, chain of trust, boot hash)
- vbmeta Flags remain 0 (no disabled flags)

**Magisk boot is the more secure option** for modified partitions because dm-verity still runs and can detect issues, whereas the disabled flag turns it off entirely.

## Unsolved Question

Why exactly does the host-computed hashtree not match what the device reads? This remains unsolved. The data appears identical from avbtool's perspective, but the device disagrees. Further investigation would require:
- Dumping the raw partition from the device and comparing byte-by-byte with the image we flashed
- Analyzing the exact dm-verity error from kernel logs (device has no pstore/last_kmsg)
- Testing with different Linux kernel versions or mount options on the host
