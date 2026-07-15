# Modified Stock Apps

Pre-modified APKs with signatures stripped. Sign with your own keys before installing.

## Sign before use

```bash
java -Djava.library.path=../ROM_resigner/Linux \
    -jar ../ROM_resigner/signapk.jar \
    --min-sdk-version 24 \
    ../certs/aosp/platform.x509.pem ../certs/aosp/platform.pk8 \
    PackageInstaller/PackageInstaller_unsigned.apk PackageInstaller/PackageInstaller.apk
```

## Modifications

### /system/priv-app/PackageInstaller/PackageInstaller.apk

- Blocks all APK installations with "Not Allowed" toast

### /system/priv-app/Settings/Settings.apk

- Blocks developer options (build number tap disabled)

### /system/framework/framework-res.apk

- Hides "System Update" USB mode label (replaced with blank)
