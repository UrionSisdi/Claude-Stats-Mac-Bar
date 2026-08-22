#!/bin/bash
# Creates a trusted self-signed code signing certificate.
# Needed so macOS remembers Always Allow for the Claude Code-credentials keychain item.
set -euo pipefail

NAME="ClaudeStats Self-Signed"
P12_PASS="claudestats"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Certificate $NAME is already valid."
    exit 0
fi

# Already imported but not trusted yet: adding trust is enough.
if security find-certificate -c "$NAME" -p > "$TMP/existing.pem" 2>/dev/null &&
   [ -s "$TMP/existing.pem" ]; then
    echo "macOS will ask for your password once, to trust the certificate."
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/existing.pem"
    security find-identity -v -p codesigning | grep -q "$NAME" &&
        { echo "Certificate $NAME is now trusted."; exit 0; }
fi

cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/openssl.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

# OpenSSL 3 defaults to a PKCS#12 flavour macOS cannot read.
openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -passout "pass:$P12_PASS" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

security import "$TMP/cert.p12" -k "$KEYCHAIN" -T /usr/bin/codesign -P "$P12_PASS" >/dev/null

echo "macOS will ask for your password once, to trust the certificate."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Certificate $NAME created and trusted."
else
    echo "Certificate created but is not a valid identity. Check its trust in Keychain Access."
    exit 1
fi
