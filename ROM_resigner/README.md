# ROM_resigner

Forked from [ybtag/ROM_resigner](https://github.com/ybtag/ROM_resigner) (GPL-3.0).

Python script to resign an Android ROM using custom keys.

## Modifications from upstream

1. **v3 APK signing block fallback** - extracts certs from v3 signing block for APKs without v1 signatures (META-INF/CERT.RSA/.EC/.DSA)
2. **Fixed mac_permissions rewrite** - replaced `fileinput` + `print(line, end=' ')` with clean `read()/write()` (original added trailing spaces that corrupted cert hex)
3. **Duplicate cert detection** - warns if same cert appears in multiple mac_permissions entries (causes PolicyComparator rejection)
4. **Default keys path** - `SecurityDir` now optional, defaults to `AOSP_security/` in script directory
5. **`--min-sdk-version 24`** - added to signapk.jar command (required for EC key signing)
6. **ADB flag** - optional `adb` argument to patch default.prop/build.prop for insecure ADB
7. **Removed debug print** - removed `print(signjarcmd)` that printed every signing command

Sample usage (based on the repo folder design):
- `python3 ROM_resigner/resign.py "system/system,vendor,product" ROM_resigner/AOSP_security`
- `python3 ROM_resigner/resign.py "system,vendor,product" ROM_resigner/AOSP_security`

This code is released on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied!

HIGH-RISK CODE!!! USE AT OWN RISK!!!!!! YOU MAY BRICK OR DESTROY YOUR DEVICE!!! 
IT SHOULD ONLY BE USED ON DEVELOPMENT SYSTEMS!

PLEASE DO NOT USE IF YOU DO NOT UNDERSTAND WHAT YOU ARE DOING OR YOU ARE NOT WILLING TO EXCEPT THE RISK OF DESTROYING YOUR DEVICE!!!

YOU HAVE BEEN WARNED!!!

