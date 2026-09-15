#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Create a self-signed code-signing certificate, idempotently.
#
# WHY THIS EXISTS
# ---------------
# Ad-hoc signing (`codesign -s -`) gives a designated requirement of:
#
#     designated => cdhash H"67a9a7e4..."
#
# TCC stores that requirement when the user grants Screen Recording. Because the
# cdhash changes on *every single build*, the grant silently stops matching after
# any rebuild — while System Settings still shows a ticked box for the old hash.
# The symptom is maddening: the app keeps asking for a permission that Settings
# insists is already granted.
#
# Signing with a certificate instead gives:
#
#     designated => identifier "app.screensculpt.ScreenSculpt"
#                   and certificate leaf = H"6a399cd8..."
#
# That requirement is stable across rebuilds, so the grant persists.
#
# This does NOT help with Gatekeeper — a self-signed certificate is not a
# Developer ID, so downloads still need "Open Anyway" once. It fixes the
# permission problem, which is the one that recurs.
#
# The certificate is untrusted for verification purposes, which is fine: TCC
# matches the certificate hash, it does not evaluate the trust chain.

set -euo pipefail

CERT_NAME="${SCREENSCULPT_CERT_NAME:-ScreenSculpt Local Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  HASH="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
          | grep -F "$CERT_NAME" | head -1 | awk '{print $2}')"
  echo "Certificate already present: $CERT_NAME"
  echo "  SHA-1: ${HASH:-unknown}"
  echo
  echo "Builds will use it automatically. Nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a self-signed code-signing certificate"
cat > "$WORK/cs.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $CERT_NAME
[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 \
  -keyout "$WORK/cs.key" -out "$WORK/cs.crt" \
  -days 3650 -nodes -config "$WORK/cs.cnf" 2>/dev/null

# OpenSSL 3 defaults to AES-256 for PKCS#12, which macOS Security cannot read;
# the legacy PBE algorithms below are required or `security import` fails with
# "MAC verification failed".
openssl pkcs12 -export \
  -inkey "$WORK/cs.key" -in "$WORK/cs.crt" -out "$WORK/cs.p12" \
  -name "$CERT_NAME" -passout pass:screensculpt \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "==> Importing into the login keychain"
# -A so codesign can use the key without a prompt on every build.
security import "$WORK/cs.p12" -k "$KEYCHAIN" -P screensculpt -A -T /usr/bin/codesign

HASH="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
        | grep -F "$CERT_NAME" | head -1 | awk '{print $2}')"

echo
echo "==> Done"
echo "    Certificate: $CERT_NAME"
echo "    SHA-1:       ${HASH:-unknown}"
echo
echo "    Builds now produce a stable designated requirement, so the Screen"
echo "    Recording grant survives rebuilds."
echo
echo "    It will be listed as CSSMERR_TP_NOT_TRUSTED — that is expected and"
echo "    harmless. TCC matches the certificate hash; it does not evaluate trust."
echo
echo "    Keep this certificate. Replacing it invalidates every user's grant,"
echo "    exactly like the ad-hoc problem it solves."
