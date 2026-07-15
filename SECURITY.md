# Security Notice

## Key Types: Included vs Generated

This repository includes **AVB keys** but requires users to **generate APK/OTA keys**.

### AVB Keys (INCLUDED)

The AVB signing keys are **included in the repository**:
- `keys/vbmeta.pem` - AOSP testkey RSA 4096
- `keys/vbmeta_system.pem` - AOSP testkey RSA 2048

**Why these are included:**
- The E4810's bootloader has a fused root of trust matching these specific AOSP test keys
- Random keys will NOT work - the device will show "device is corrupt" and refuse to boot
- These are **public AOSP test keys** from `platform/external/avb/test/data/`, not private credentials
- Key SHA1 hashes: vbmeta=`2597c218aae470a130f61162feaae70afd97f011`, system=`cdbb77177f731920bbe0a0f94f84d9038ae0617d`

### APK/OTA Keys (GENERATED)

Users must configure and generate their own APK and OTA signing keys:

1. Edit `keys.conf` to customize each key's identity (CN, Org, Country)
2. Run `./scripts/generate_keys.sh`

```
# keys.conf format: SEINFO|CN|ORG|COUNTRY
platform|mycompany-platform|My Company|US
media|mycompany-media|My Company|US
verizon|mycompany-verizon|My Company|US
```

**Why these are generated:**
- APK signing keys are used to replace Kyocera's platform keys with your own
- Each deployment should have unique APK keys for security
- OTA keys are for signing custom update packages
- Full customization lets you use your own identity/organization

## APK Signing Keys

Each seinfo type in `mac_permissions.xml` requires a unique signing key:

| seinfo | Purpose |
|--------|---------|
| platform | System apps (Settings, SystemUI, framework-res) |
| media | MediaProvider, DownloadProvider |
| verizon | Verizon carrier apps |
| ssgapp | Samsung security apps (if present) |
| sysmonapp | System monitor apps |

Using the same key for multiple seinfo types causes Android's `PolicyComparator` to reject ALL policies, crashing every app.

## Key Locations

| Path | Type | Purpose |
|------|------|---------|
| `keys/vbmeta.pem` | INCLUDED | AVB vbmeta signing (AOSP testkey RSA 4096) |
| `keys/vbmeta_system.pem` | INCLUDED | AVB system chain signing (AOSP testkey RSA 2048) |
| `certs/aosp/*.pk8` | GENERATED | APK signing private keys (EC P-256) |
| `certs/aosp/*.x509.pem` | GENERATED | APK signing certificates |
| `certs/ota/payload.pem` | GENERATED | OTA payload signing |
| `certs/ota/ota.pem` | GENERATED | OTA ZIP signing |
| `app_keystore/*.jks` | GENERATED | JKS keystores for apksigner (platform, media, verizon) |

## Obtaining Stock Firmware Images

To use this toolkit, you need stock partition images (system.img, vendor.img, product.img, boot.img, dtbo.img).

**Download stock E4810 firmware from Kyocera:**
http://perpetuity.kyocera.co.jp/pctool/kcfirmware/binfile66.bin

Extract the partition images and place them in `firmware/stock/`.
