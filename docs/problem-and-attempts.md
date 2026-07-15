# Problem Statement & Attempts Log

## Goal
Replace Kyocera's platform signing keys on the E4810 (DuraXV Extreme, Android 9) with custom signing keys, so modified system APKs can be installed with custom signatures while maintaining AVB chain integrity.

## Final Working Solution

- **Magisk boot** (boot(1).img) - required for dm-verity handling
- **APK re-signing** with ybtag ROM_resigner fork using unique EC keys per seinfo
- **Two-pass AVB** with kernel cmdline descriptors (for stock boot compatibility research)
- **No vbmeta padding**, no duplicate props
- **Both A/B slots** flashed
- **SELinux enforcing**, 0 crashes, dev options working

## Issues Discovered & Solved

### 1. ROM_resigner EC Cert Support
**Problem:** Original ROM_resigner only handles RSA certs (CERT.RSA). Kyocera uses EC certs.
**Solution:** ybtag fork handles EC/DSA certs. Added v3 signing block fallback for v3-only APKs.

### 2. PolicyComparator Duplicate Rejection
**Problem:** Using same signing key for all seinfo types causes `PolicyComparator` to reject ALL policies. Every app gets `seinfo=default` and crashes.
**Root cause:** Decompiled from `services.vdex` - `PolicyComparator.compare()` checks cert equality across ALL mac_permissions files (system + vendor).
**Solution:** Generate unique EC P-256 key per seinfo type (platform, media, verizon).

### 3. mac_permissions Space Corruption
**Problem:** ybtag's `print(line, end=' ')` adds trailing spaces to cert hex in XML.
**Solution:** Replaced with clean `read()/write()` in resign.py.

### 4. A/B Slot Mismatch
**Problem:** Flashing only one slot causes "device is corrupt" - bootloader checks both.
**Solution:** Flash all partitions to both `_a` and `_b` slots.

### 5. vbmeta Padding & Duplicate Props
**Problem:** Stock vbmeta is ~4KB. Our 64KB padded vbmeta with duplicate props caused issues.
**Solution:** Remove `--padding_size 65536` and explicit `--prop` flags from `rebuild_vbmeta.sh`.

### 6. dm-verity Runtime Failure (UNSOLVED for stock boot)
**Problem:** Modifying files on ext4 images (even `cp` of same file) breaks dm-verity runtime verification with stock boot.
**Root cause:** Unknown - ext4 block-level data differs between host Linux and Android device after mount/modify/unmount cycle.
**Workaround:** Magisk boot handles dm-verity errors non-fatally.
**See:** `docs/dm-verity-issue.md` for full details.

## Attempt Log

| # | Approach | Result | Cause |
|---|----------|--------|-------|
| 1 | apksigner v1+v2 + zipalign | Apps crash | Changed ZIP structure, broke .odex |
| 2 | apksigner v3-only | Apps crash | SELinux seinfo=default |
| 3 | ROM_resigner original | 0 APKs signed | Only handles RSA, Kyocera uses EC |
| 4 | signapk.jar manual | Apps crash or bootloop | Various |
| 5 | signapk.jar + delete all odex | Bootloop | Deleted framework boot classpath |
| 6 | signapk.jar + delete app odex | Bootloop | CtsShimPrivPrebuilt corrupted |
| 7 | ybtag ROM_resigner (RSA key) | Apps crash | Duplicate certs in mac_permissions |
| 8 | ybtag ROM_resigner (EC key, single) | Apps crash | Same duplicate cert issue |
| 9 | ybtag ROM_resigner (EC key, unique per seinfo) | **Works** | Fixed duplicates |
| 10 | Stock boot + resigned system | Stuck at logo | dm-verity failure |
| 11 | Stock boot + disabled dm-verity flag | Boots | Confirms dm-verity is the issue |
| 12 | Stock boot + patched sepolicy | Stuck at logo | Sepolicy not the issue |
| 13 | Stock boot + kernel cmdline descriptors | Boots for small edits only | dm-verity fails for file copies |
| 14 | Magisk boot + resigned system | **Works** | Magisk handles dm-verity |
