# E4810 OTA Update Creator

Create custom-signed A/B OTA update packages for the Kyocera DuraXV Extreme (E4810) that are accepted by `update_engine` - the same mechanism Kyocera/Verizon uses for official updates. Tested and working on Android 9 Pie.

## How It Works

The E4810 uses Android's A/B update system (`update_engine`). OTA updates are ZIP files containing a `payload.bin` with compressed partition images. Two verification layers:

1. **Payload signature** - `update_engine` verifies `payload.bin` against `/system/etc/update_engine/update-payload-key.pub.pem`
2. **ZIP signature** - verified against `/system/etc/security/otacerts.zip`

We replaced both keys in the system image with our own (in `../certs/ota/`), so the device accepts updates signed with our keys.

## Signing Keys

All keys in `../certs/ota/` (repo root):

| File | Purpose |
|------|---------|
| `ota.pem` | OTA ZIP signing private key (RSA 2048) |
| `ota.x509.pem` | OTA ZIP signing certificate (CN=example-ota) |
| `ota.pk8` | OTA private key in PKCS#8 DER (for signapk.jar) |
| `otacerts.zip` | Certificate bundle installed in system image |
| `payload.pem` | Payload signing private key (RSA 2048) |
| `payload.pub.pem` | Payload public key (installed as update-payload-key.pub.pem) |

## Quick Start

### One-command workflow

```bash
cd update_creator

# 1. Prepare images (converts sparse, pads to partition size)
./scripts/prepare_images.sh product vbmeta

# 2. Build signed OTA package
./scripts/build_ota.sh

# 3. Push to device and apply
./scripts/push_ota.sh

# 4. Reboot and verify
adb reboot
# (wait for boot)
./scripts/verify_ota.sh
```

### Manual workflow

#### Step 1: Modify the partition

```bash
# Example: add an APK to product partition
simg2img ../output/product.img /tmp/product_work.img
python3 ../tools/avb-tools/avbtool.py erase_footer --image /tmp/product_work.img
sudo mount -o loop /tmp/product_work.img /tmp/product_mnt

# Make modifications (add apps, edit configs, etc.)
sudo mkdir -p /tmp/product_mnt/priv-app/MyApp
sudo cp MyApp.apk /tmp/product_mnt/priv-app/MyApp/MyApp.apk
sudo chown root:root /tmp/product_mnt/priv-app/MyApp/MyApp.apk
sudo chmod 644 /tmp/product_mnt/priv-app/MyApp/MyApp.apk
sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" /tmp/product_mnt/priv-app/MyApp
sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" /tmp/product_mnt/priv-app/MyApp/MyApp.apk

sudo umount /tmp/product_mnt
img2simg /tmp/product_work.img ../firmware/custom/product.img
```

#### Step 2: AVB resign + rebuild vbmeta

```bash
../scripts/resign_product.sh ../firmware/custom/product.img
../scripts/rebuild_vbmeta.sh
../scripts/verify_chain.sh
```

#### Step 3: Prepare images for OTA (keep AVB footers)

```bash
./scripts/prepare_images.sh product vbmeta
```

#### Step 4: Build, push, apply

```bash
./scripts/build_ota.sh
./scripts/push_ota.sh
adb reboot
./scripts/verify_ota.sh
```

## Critical Rules

### Images MUST keep AVB footers

Partition images (system, vendor, product) must include their AVB hashtree + FEC data. The OTA writes raw bytes to the partition - if the AVB footer is missing, the bootloader rejects the partition on next boot.

Only `vbmeta.img` has no footer to worry about (it IS the verification metadata).

**prepare_images.sh handles this automatically** - it converts sparse to raw but does NOT strip AVB footers.

### Always include vbmeta when updating other partitions

When you update system, vendor, or product, the vbmeta hashtree descriptors must match the new partition data. Always include vbmeta in the same OTA update.

### Filenames = partition names

`payload_packer` derives partition names from filenames. `product.img` writes to partition `product`. Using `product_new.img` or `product_avb.img` causes `kInstallDeviceOpenError` because partition `product_new` doesn't exist.

### Compression: bzip2 only

**Use `--method bz2`**, not xz. Android 9's `update_engine` has an older XZ decoder that rejects the compression options `payload_packer` uses (`XZ_OPTIONS_ERROR`). bzip2 works reliably.

### Properties file must be pushed, not inlined

The `payload_properties.txt` contains base64 hashes with `+`, `/`, and `=` characters. Shell heredocs and argument passing strip or mangle these. The apply script reads properties from a file on device instead.

### No incremental/delta updates

This device's `update_engine` only supports `minor_version=0` (full payloads). Any delta payload (`minor_version > 0`) is rejected with `kUnsupportedMinorPayloadVersion`. Kyocera compiled update_engine without incremental support.

### Partition sizes (with AVB)

Images must be padded to these exact sizes (the full partition including AVB space):

| Partition | Size | Notes |
|-----------|------|-------|
| vbmeta | 65,536 (64KB) | Raw, no AVB footer |
| boot | 33,554,432 (32MB) | |
| system | 922,746,880 (~880MB) | Sparse → raw, keep AVB |
| vendor | 524,288,000 (~500MB) | Sparse → raw, keep AVB |
| product | 524,288,000 (~500MB) | Sparse → raw, keep AVB |
| dtbo | 1,310,720 (~1.3MB) | |

## Payload Signing Details

### CrAU Payload Format (v2)

```
+-------------------+  byte 0
| Magic "CrAU"      |  4 bytes
+-------------------+  byte 4
| Version (2)        |  8 bytes, uint64 big-endian
+-------------------+  byte 12
| Manifest size      |  8 bytes, uint64 big-endian
+-------------------+  byte 20
| Metadata sig size  |  4 bytes, uint32 big-endian
+-------------------+  byte 24
| Manifest           |  (protobuf DeltaArchiveManifest)
+-------------------+  byte 24 + manifest_size
| Metadata signature |  (protobuf Signatures)
+-------------------+  byte 24 + manifest_size + metadata_sig_size
| Blob data          |  (compressed partition data)
+-------------------+  byte 24 + manifest_size + metadata_sig_size + blob_size
| Payload signature  |  (protobuf Signatures)
+-------------------+
```

### Two Signatures

**Metadata signature** - signs `header + manifest` (first `24 + manifest_size` bytes):
```
metadata_hash = SHA256(payload[0 : 24 + manifest_size])
```

**Payload signature** - signs `header + manifest + blob`, **EXCLUDING metadata signature**:
```
payload_hash = SHA256(header || manifest || blob_data)
```

This is non-obvious: `update_engine` computes the payload hash by concatenating header + manifest + blob, skipping over the metadata signature bytes entirely. Discovered by comparing the expected hash from the update_engine log against hashes of various byte ranges.

### Manifest Patching

`payload_packer` generates an unsigned manifest missing required fields. `sign_payload.py` appends them:

| Field | Number | Purpose |
|-------|--------|---------|
| `signatures_offset` | 4 | Byte offset from end of metadata+metasig to payload signature (= blob size) |
| `signatures_size` | 5 | Size of payload signature protobuf (262 bytes for RSA-2048) |
| `max_timestamp` | 14 | Must be >= device's `ro.build.date.utc` or rejected (`kPayloadTimestampError`) |

### Protobuf Signatures Wire Format

```
Signatures message (262 bytes total for RSA-2048):
  0x0a <varint:259>        # field 1 (Signature), length 259
    0x12 <varint:256>      # field 2 (data), length 256
      <256 bytes RSA sig>  # PKCS1 v1.5 SHA256 signature
```

## Error Reference

All errors encountered during development:

| Code | Name | Cause | Fix |
|------|------|-------|-----|
| 7 | `kInstallDeviceOpenError` | Partition name from filename doesn't match device | Name files exactly: `product.img`, `vbmeta.img` |
| 9 | `kDownloadTransferError` | SELinux blocks update_engine from reading file | Put in `/data/ota_package/` owned by `system:cache` |
| 10 | `kPayloadHashMismatchError` | FILE_HASH base64 mangled by shell (`=` stripped) | Push properties as file, read with script on device |
| 18 | `kDownloadPayloadPubKeyVerificationError` | Payload signature hash wrong | Hash = `SHA256(header + manifest + blob)` excluding metadata sig |
| 28 | `kDownloadOperationExecutionError` | XZ decompression failed | Use `--method bz2` not xz |
| 32 | `kDownloadInvalidMetadataSize` | Headers not parsed correctly | Use newline-separated headers via file, not inline |
| 45 | `kUnsupportedMinorPayloadVersion` | Delta updates not supported | Use full payloads only (minor_version=0) |
| 51 | `kPayloadTimestampError` | Payload timestamp too old | `sign_payload.py` adds `max_timestamp = now + 1 day` |

## SELinux Requirements

`update_engine` runs as `u:r:update_engine:s0`:

| Path | Context | Accessible |
|------|---------|------------|
| `/data/ota_package/` | `ota_package_file` | Yes |
| `/data/local/tmp/` | `shell_data_file` | **No** |
| `/sdcard/` | `media_rw_data_file` | **No** |

Files in `/data/ota_package/` must be owned by `system:cache`.

## Stock DmClient Reference

The stock OTA client (`/product/priv-app/DmClient/DmClient.apk`, `com.kyocera.omadm`) uses `android.os.UpdateEngine` Java API:

```java
UpdateEngine engine = new UpdateEngine();
engine.applyPayload(
    "file://" + filePath,    // or streaming URL
    offset,                   // payload.bin offset in ZIP
    size,                     // payload.bin size
    headerKeyValuePairs       // String[] from payload_properties.txt lines
);
```

A custom app using this API would have proper SELinux access and avoid all CLI quoting issues.

## Tools

| Tool | Purpose | Source |
|------|---------|--------|
| `payload_packer` | Generates unsigned payload.bin from images | [rhythmcache/payload_packer](https://github.com/rhythmcache/payload_packer) v0.1.1 |
| `sign_payload.py` | Signs payload, patches manifest protobuf | Custom |
| `signapk.jar` | Signs OTA ZIP whole-file | AOSP (in `ROM_resigner/`) |

## Directory Structure

```
update_creator/
├── README.md                  # This file
├── payload_packer             # Generates unsigned payload.bin (Linux x86_64)
├── sign_payload.py            # Signs payload + patches manifest
├── scripts/
│   ├── prepare_images.sh      # Convert output/ images to raw, pad to partition size
│   ├── build_ota.sh           # Generate payload, sign, build ZIP (full pipeline)
│   ├── push_ota.sh            # Push to device, apply via update_engine
│   └── verify_ota.sh          # Verify partition hashes match after reboot
├── raw_images/                # Input: raw partition images (with AVB, padded)
│   ├── product.img
│   └── vbmeta.img
├── output/                    # Output: build artifacts
│   ├── payload.bin            # Unsigned payload
│   ├── payload_signed.bin     # Signed payload
│   ├── payload_properties.txt # Hashes and sizes for update_engine headers
│   └── update.zip             # Final signed OTA package
├── DmClient.apk              # Stock Kyocera OTA client (reference/decompiled)
├── payload_packer.zip         # Original download archive
└── sha256sum.txt              # payload_packer checksum
```
