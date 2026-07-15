#!/usr/bin/env python3
"""Generate EC P-256 key in compact PKCS#8 DER format (67 bytes, without public key).

This matches the exact format used by the original keys - signapk.jar and
Android's APK signature verification require this specific encoding.

Usage: python3 gen_compact_pk8.py <output.pk8>
Also outputs <output.pem> for certificate generation.
"""
import sys
import os

try:
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.backends import default_backend
except ImportError:
    print("ERROR: cryptography module required. Install with: pip3 install cryptography")
    sys.exit(1)

def generate_compact_ec_key(pk8_path):
    """Generate EC P-256 key and save in compact PKCS#8 format."""
    # Generate EC key
    private_key = ec.generate_private_key(ec.SECP256R1(), default_backend())

    # Get the private key bytes (32 bytes for P-256)
    private_numbers = private_key.private_numbers()
    private_bytes = private_numbers.private_value.to_bytes(32, byteorder='big')

    # Build compact ECPrivateKey (without optional publicKey field)
    # ECPrivateKey ::= SEQUENCE {
    #   version INTEGER { ecPrivkeyVer1(1) }
    #   privateKey OCTET STRING
    # }
    ec_private_key = bytes([
        0x30, 0x25,  # SEQUENCE, 37 bytes
        0x02, 0x01, 0x01,  # INTEGER version = 1
        0x04, 0x20  # OCTET STRING, 32 bytes (private key)
    ]) + private_bytes

    # Build PKCS#8 wrapper
    # PrivateKeyInfo ::= SEQUENCE {
    #   version INTEGER
    #   algorithm AlgorithmIdentifier
    #   privateKey OCTET STRING
    # }
    algorithm_id = bytes([
        0x30, 0x13,  # SEQUENCE, 19 bytes
        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,  # OID: id-ecPublicKey
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07  # OID: prime256v1
    ])

    pkcs8 = bytes([
        0x30, 0x41,  # SEQUENCE, 65 bytes total
        0x02, 0x01, 0x00  # INTEGER version = 0
    ]) + algorithm_id + bytes([0x04, 0x27]) + ec_private_key

    # Write compact PKCS#8 DER
    with open(pk8_path, 'wb') as f:
        f.write(pkcs8)

    # Also write PEM format for openssl/keytool compatibility
    pem_path = pk8_path.replace('.pk8', '.pem')
    if pem_path == pk8_path:
        pem_path = pk8_path + '.pem'

    pem_data = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption()
    )
    with open(pem_path, 'wb') as f:
        f.write(pem_data)

    return pem_path

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <output.pk8>")
        sys.exit(1)

    pk8_path = sys.argv[1]
    pem_path = generate_compact_ec_key(pk8_path)
    print(f"Generated: {pk8_path} (67 bytes)")
    print(f"Generated: {pem_path}")
