#!/usr/bin/python
from xml.dom import minidom
import re
import os
import mmap
import subprocess
import fnmatch
import argparse
import fileinput
import codecs

cwd = os.path.dirname(os.path.realpath(__file__))
useApkSigner = False # If you prefer, set this to True if you have apksigner installed

def find(pattern, path):
    for root, dirs, files in os.walk(path):
        for name in files:
            if fnmatch.fnmatch(name, pattern):
                return os.path.join(root, name)

parser = argparse.ArgumentParser(
    description="Python Script to resign an Android ROM using custom keys")
parser.add_argument('RomDir', help='ROM Path. You can pass multiple folders, separated by comma')
parser.add_argument(
    'SecurityDir', nargs='?', default=cwd + "/AOSP_security",
    help='Security Dir Path (default: AOSP_security in script dir)')
parser.add_argument('enable_adb', nargs='?', choices=['adb'],
    help='Pass "adb" to enable ADB without authorization dialog')
args = parser.parse_args()
itemlist = []
seinfos = []
mac_permissions = []
romdir = args.RomDir.split(',')
for i in range(len(romdir)):
    romdir[i] = os.path.abspath(romdir[i])
    #print (romdir[i])
    mac_permissions_file = find("*mac_permissions*", romdir[i] + "/etc/selinux")
    if mac_permissions_file != None:
        #print (mac_permissions_file)
        mac_permissions.append(mac_permissions_file)
        xmldoc = minidom.parse(mac_permissions_file)
        itemlist += xmldoc.getElementsByTagName('signer')
        for seinfo in xmldoc.getElementsByTagName('seinfo'):
            seinfos.append(seinfo.attributes['value'].value)
    
securitydir = os.path.abspath(args.SecurityDir)

certlen = len(itemlist)

signatures = []
signatures64 = []
usedseinfos = []

tmpdir = cwd + "/tmp"
signapkjar = cwd + "/signapk.jar"
os_info = os.uname()[0]
signapklibs = cwd + "/" + os_info

def CheckCert(filetoopen, cert):
    with open(filetoopen, 'rb') as f:
        s = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        if s.find(cert) != -1:
            #print("checkcert passed")
            return True
    #print("checkcert failed")
    return False

def getcert(jar, out):
    # Try v1 first (META-INF/CERT.RSA, CERT.EC, CERT.DSA)
    try:
        listmeta = f"7z l {jar} META-INF/*"
        output = subprocess.check_output(['bash', '-c', listmeta]).decode()
        cert_files = re.findall(r"META-INF/(.*?\.(RSA|EC|DSA))", output)

        for cert_file, _ in cert_files:
            extractjar = f"7z e {jar} META-INF/{cert_file} -o{tmpdir}"
            x = subprocess.run(['7z', 't', jar], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if x.returncode == 0:
                try:
                    output = subprocess.check_output(['bash', '-c', extractjar])
                    if os.path.exists(f"{tmpdir}/{cert_file}"):
                        extractcert = f"openssl pkcs7 -in {tmpdir}/{cert_file} -print_certs -inform DER -out {out}"
                        output = subprocess.check_output(['bash', '-c', extractcert])
                        os.remove(f"{tmpdir}/{cert_file}")
                        return
                except subprocess.CalledProcessError:
                    continue
    except subprocess.CalledProcessError:
        pass

    # Fallback: extract cert from v3 APK Signing Block
    try:
        import struct
        with open(jar, 'rb') as f:
            data = f.read()
        eocd = data.rfind(b'\x50\x4b\x05\x06')
        if eocd < 0:
            return
        cd_offset = struct.unpack_from('<I', data, eocd + 16)[0]
        magic = data.rfind(b'APK Sig Block 42', 0, cd_offset)
        if magic < 0:
            return
        block_size = struct.unpack_from('<Q', data, cd_offset - 24)[0]
        pos = cd_offset - block_size - 8 + 8
        while pos < cd_offset - 24:
            pair_size = struct.unpack_from('<Q', data, pos)[0]
            pair_id = struct.unpack_from('<I', data, pos + 8)[0]
            if pair_id == 0xf05368c0:  # v3
                v3 = data[pos + 12:pos + 8 + pair_size]
                off = 0
                off += 4  # signers_seq_len
                off += 4  # signer_len
                sd_len = struct.unpack_from('<I', v3, off)[0]; off += 4
                sd = v3[off:off + sd_len]
                sd_off = 0
                dig_len = struct.unpack_from('<I', sd, sd_off)[0]; sd_off += 4 + dig_len
                sd_off += 4  # certs_len
                cert_len = struct.unpack_from('<I', sd, sd_off)[0]; sd_off += 4
                cert_der = sd[sd_off:sd_off + cert_len]
                # Write as PEM
                import base64
                pem = "-----BEGIN CERTIFICATE-----\n"
                pem += base64.encodebytes(cert_der).decode()
                pem += "-----END CERTIFICATE-----\n"
                with open(out, 'w') as f:
                    f.write(pem)
                return
            pos += 8 + pair_size
    except Exception:
        pass

def sign(jar, certtype):
    if not os.path.exists(securitydir + "/" + certtype + ".pk8"):
        print((certtype + ".pk8 not found in security dir"))
        return False

    jartmpdir = tmpdir + "/JARTMP"
    if not os.path.exists(jartmpdir):
        os.makedirs(jartmpdir)

    signjarcmd = "java -XX:+UseCompressedOops -XX:+PerfDisableSharedMem -Xms2g -Xmx2g -Djava.library.path=" + signapklibs + " -jar " + signapkjar + " --min-sdk-version 24 " + securitydir + \
        "/" + certtype + ".x509.pem " + securitydir + "/" + certtype + \
        ".pk8 " + jar + " " + jartmpdir + "/" + os.path.basename(jar)
    movecmd = "mv -f " + jartmpdir + "/" + os.path.basename(jar) + " " + jar
    try:
        output = subprocess.check_output(['bash', '-c', signjarcmd])
        output += subprocess.check_output(['bash', '-c', movecmd])
        print((os.path.basename(jar) + " signed as " + seinfo))
        usedseinfos.append(
            seinfo) if seinfo not in usedseinfos else usedseinfos
    except subprocess.CalledProcessError:
        print(("Signing " + os.path.basename(jar) + " failed"))

def zipalign(jar):
    jartmpdir = tmpdir + "/JARTMP"
    if not os.path.exists(jartmpdir):
        os.makedirs(jartmpdir)

    zipaligncmd = "zipalign -f -p 4 " + jar + " " + jartmpdir + "/" + os.path.basename(jar)

    movecmd = "mv -f " + jartmpdir + "/" + os.path.basename(jar) + " " + jar
    try:
        output = subprocess.check_output(['bash', '-c', zipaligncmd])
        output += subprocess.check_output(['bash', '-c', movecmd])
        print((os.path.basename(jar) + " zipaligned"))
    except subprocess.CalledProcessError:
        print(("Zipaligning " + os.path.basename(jar) + " failed"))

def apksign(jar, certtype):
    apksigncmd = "apksigner sign --key " + securitydir + "/" + certtype + ".pk8 --cert " + securitydir + "/" + certtype + ".x509.pem  " + jar
    #print (apksigncmd)
    try:
        output = subprocess.check_output(['bash', '-c', apksigncmd])
        print((os.path.basename(jar) + " apksigned"))
    except subprocess.CalledProcessError:
        print(("Apksigning " + os.path.basename(jar) + " failed"))

def recontext(jar):
    contextcmd = 'sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" ' + jar
    try:
        output = subprocess.check_output(['bash', '-c', contextcmd])
        print("Restored context for " + (os.path.basename(jar)))
    except subprocess.CalledProcessError:
        print(("Restoring context for " + os.path.basename(jar) + " failed"))

index = 0
for s in itemlist:
    signatures.append(s.attributes['signature'].value)
    test64 = codecs.encode(codecs.decode(
        s.attributes['signature'].value, 'hex'), 'base64').decode()
    test64 = test64.replace('\n', '')

    signatures64.append(re.sub("(.{64})", "\\1\n", test64, 0, re.DOTALL))

if not os.path.exists(tmpdir):
    os.makedirs(tmpdir)

# Enable ADB if requested
if args.enable_adb == 'adb':
    for romdirItem in romdir:
        # Find system partition (has default.prop and build.prop)
        default_prop = os.path.join(romdirItem, '../default.prop') if '/system' in romdirItem else None
        build_prop = os.path.join(romdirItem, 'build.prop') if '/system' in romdirItem else None
        if default_prop and os.path.exists(default_prop):
            with open(default_prop, 'r') as f:
                content = f.read()
            content = content.replace('ro.adb.secure=1', 'ro.adb.secure=0')
            content = content.replace('ro.debuggable=0', 'ro.debuggable=1')
            with open(default_prop, 'w') as f:
                f.write(content)
            print("ADB: patched default.prop")
        if build_prop and os.path.exists(build_prop):
            with open(build_prop, 'a') as f:
                f.write('\npersist.sys.usb.config=mtp,adb\n')
                f.write('ro.adb.secure=0\n')
                f.write('ro.debuggable=1\n')
                f.write('persist.service.adb.enable=1\n')
            print("ADB: patched build.prop")

for romdirItem in romdir:
    for root, dirs, files in os.walk(romdirItem):
        for file in files:
            if file.endswith(".apk") or file.endswith(".jar") or file.endswith(".apex"):
                jarfile = os.path.join(root, file)

                os.chdir(tmpdir)
                out = "foo.cer"
                if os.path.exists(out):
                    os.remove(out)

                getcert(jarfile, out)
                if not os.path.exists(out):
                    print((file + " : No signature => Skip"))
                else:
                    index = 0
                    for seinfo in seinfos:
                        if CheckCert(out, signatures64[index].encode()):
                            #zipalign(jarfile) #zipalign not needed as already alligned. Old code called it after signing, and that was worse, as it messed up signature
                            if useApkSigner:
                                apksign(jarfile, seinfo)
                            else:
                                sign(jarfile, seinfo)
                            recontext(jarfile)
                            break
                        index += 1
                    if index == certlen:
                        print((file + " : Unknown => keeping signature"))

index = 0
for s in itemlist:
    oldsignature = s.attributes['signature'].value
    seinfo = seinfos[index]
    index += 1
    if seinfo in usedseinfos:
        pemtoder = "openssl x509 -outform der -in " + \
            securitydir + "/" + seinfo + ".x509.pem"
        output = subprocess.check_output(['bash', '-c', pemtoder])
        newsignature = output.hex()
        for mac_permissions_file in mac_permissions:
            with open(mac_permissions_file, 'r') as f:
                content = f.read()
            content = content.replace(oldsignature, newsignature)
            with open(mac_permissions_file, 'w') as f:
                f.write(content)

# Verify no duplicate certs across mac_permissions files (causes PolicyComparator rejection)
import hashlib
all_certs = []
for mac_permissions_file in mac_permissions:
    with open(mac_permissions_file, 'r') as f:
        content = f.read()
    sigs = re.findall(r'signature="([^"]+)"', content)
    for sig in sigs:
        cert_hash = hashlib.sha1(codecs.decode(sig, 'hex')).hexdigest()
        all_certs.append((mac_permissions_file, cert_hash))

seen = {}
has_duplicate = False
for filepath, cert_hash in all_certs:
    if cert_hash in seen:
        print(f"WARNING: Duplicate cert {cert_hash} in {os.path.basename(filepath)} and {os.path.basename(seen[cert_hash])}")
        print("This WILL cause Android's PolicyComparator to reject ALL policies!")
        print("Fix: use a unique key (.pk8/.x509.pem) for each seinfo type.")
        has_duplicate = True
    else:
        seen[cert_hash] = filepath

if not has_duplicate:
    print("No duplicate certs across mac_permissions files - safe.")

# NOTE: AVB re-signing is handled separately via the scripts/ directory.
# After running this script, unmount partitions, convert to sparse, then run:
#   ./scripts/resign_system.sh firmware/custom/system.img
#   ./scripts/resign_product.sh firmware/custom/product.img
#   ./scripts/resign_vendor.sh firmware/custom/vendor.img
#   ./scripts/rebuild_vbmeta.sh
#   ./scripts/verify_chain.sh
