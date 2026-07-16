#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Algorithm-agnostic PCR-signing public-key fingerprint, matching systemd's
# own pubkey_fingerprint() exactly (systemd v261 src/shared/crypto-util.c):
# SHA256 of the OpenSSL i2d_PublicKey(pk) DER encoding of the key. That
# encoding is algorithm-specific:
#   - RSA: PKCS#1 RSAPublicKey DER
#     (== `openssl rsa -pubin -RSAPublicKey_out -outform DER`
#      == cryptography's Encoding.DER + PublicFormat.PKCS1)
#   - EC:  the raw uncompressed point 0x04||X||Y (NOT SubjectPublicKeyInfo)
#     (== cryptography's Encoding.X962 + PublicFormat.UncompressedPoint)
#
# This is the exact byte string whose SHA256 appears as the "pkfp" value in
# a UKI's .pcrsig JSON section, and is what systemd-cryptenroll stores
# (indirectly, via the same key) as the TPM2 token's public-key identity.
# Used by test/native-ab-secure-artifact-test.sh, test/native-ab-secure-
# update-test.sh, and test/native-ab-secure-rotation-test.sh so those tests
# work for both the legacy RSA-4096 key and the current ECC P-256 key
# (RSA-4096 trips systemd issue #30546 / Esys_LoadExternal TPM_RC_VALUE
# during TPM auto-unlock).
#
# Usage: pubkey-fingerprint.py [PEM_FILE]
#   Reads a PEM-encoded public key from PEM_FILE, or from stdin if omitted.
#   Prints the lowercase hex SHA256 fingerprint, newline-terminated.

import sys
from hashlib import sha256

from cryptography.hazmat.primitives.asymmetric.ec import EllipticCurvePublicKey
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicKey
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    PublicFormat,
    load_pem_public_key,
)


def main() -> int:
    if len(sys.argv) > 2:
        print("Error: at most one argument (a PEM public key file) is accepted", file=sys.stderr)
        return 2

    if len(sys.argv) == 2:
        with open(sys.argv[1], "rb") as f:
            pem = f.read()
    else:
        pem = sys.stdin.buffer.read()

    key = load_pem_public_key(pem)

    if isinstance(key, RSAPublicKey):
        der = key.public_bytes(Encoding.DER, PublicFormat.PKCS1)
    elif isinstance(key, EllipticCurvePublicKey):
        der = key.public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)
    else:
        print(f"Error: unsupported public key type: {type(key).__name__}", file=sys.stderr)
        return 1

    print(sha256(der).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
