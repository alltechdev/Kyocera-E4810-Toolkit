# SELinux mac_permissions Investigation

## PolicyComparator Duplicate Detection - ROOT CAUSE OF APP CRASHES

### The Problem
After re-signing APKs and updating mac_permissions.xml, all apps crashed with:
```
selinux_android_setcontext(1000, 0, "default:privapp:targetSdkVersion=19:complete",
"com.android.settings:CryptKeeper") failed
```
Every app got `seinfo=default` instead of `platform` or `media`.

### Root Cause
Decompiled `PolicyComparator` from `services.vdex` (using baksmali):

```java
// PolicyComparator.compare(Policy p1, Policy p2)
if (p1.mCerts.equals(p2.mCerts)) {     // Same cert across ANY two entries
    if (p1.hasGlobalSeinfo()) {          // Either has global seinfo
        duplicateFound = true;           // → DUPLICATE!
    }
}

// readInstallPolicy()
if (comparator.foundDuplicate()) {
    Slog.w("SELinuxMMAC", "ERROR! Duplicate entries found");
    return false;  // No policies loaded → all apps get seinfo=default
}
```

The comparison happens across ALL mac_permissions files (system + vendor). When the same cert appeared in `plat_mac_permissions.xml` (seinfo=platform) and `vendor_mac_permissions.xml` (seinfo=verizon), it triggered duplicate detection and rejected the ENTIRE policy.

### The Fix
Generate unique EC P-256 keys per seinfo type:
- Platform key (example-platform) - for platform seinfo
- Media key (example-media) - for media seinfo
- Verizon key (example-verizon) - for verizon seinfo

### Why It Happened
The ybtag ROM_resigner replaces certs by matching APK signatures against mac_permissions entries. When ALL seinfo types mapped to the same key, the tool replaced every cert with the same value - creating duplicates across files.

### Stock mac_permissions Structure
| File | Entry | seinfo | Original Cert |
|------|-------|--------|---------------|
| plat_mac_permissions.xml | 0 | platform (global) | Kyocera EC #1 |
| plat_mac_permissions.xml | 1 | media (global) | Kyocera EC #2 |
| vendor_mac_permissions.xml | 0 | verizon (package-level) | Verizon RSA |
| vendor_mac_permissions.xml | 1 | ssgapp (global) | Qualcomm SSG RSA |
| vendor_mac_permissions.xml | 2 | sysmonapp (global) | Qualcomm sysmon RSA |

All 5 stock certs are unique. Our replacement must maintain uniqueness.

## SELinuxMMAC Code Analysis

Decompiled from `services.vdex` using baksmali + vdexExtractor. The code is **standard AOSP** - no Kyocera modifications found.

Key flow:
1. `readInstallPolicy()` reads all mac_permissions XML files
2. Creates `Policy` objects via `PolicyBuilder.addSignature(hexString)`
3. `addSignature()` creates `new Signature(hexString)` - standard Android `Signature` class
4. `getMatchedSeInfo()` compares using `Signature.areExactMatch()`
5. Raw byte comparison - no X.509 validation, no CA:TRUE check

## Previous False Leads

1. **RSA vs EC cert format** - not the issue; both trigger duplicates
2. **Spaces in cert hex** - real bug in ybtag tool but not the root cause
3. **CA:TRUE missing** - irrelevant; AOSP code does raw byte comparison
4. **Kyocera custom code** - AOSP standard; no modifications found
5. **odex/vdex mismatch** - caused bootloop when framework oat deleted, but not the seinfo issue
6. **Single-slot flashing** - caused "corrupt" error; requires both A/B slots
