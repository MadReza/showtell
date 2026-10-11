#!/bin/bash
# Creates a self-signed "Showtell Local Signing" identity in the login keychain, so rebuilt apps
# keep the same signature and macOS keeps their permissions. Run once per Mac.
set -euo pipefail
if security find-identity -p codesigning | grep -q '"Showtell Local Signing"'; then
    echo "already there"; exit 0
fi
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$dir/key.pem" -out "$dir/cert.pem" -days 3650 -nodes \
    -subj "/CN=Showtell Local Signing" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$dir/key.pem" -in "$dir/cert.pem" -out "$dir/id.p12" -passout pass:showtell
security import "$dir/id.p12" -k ~/Library/Keychains/login.keychain-db -P showtell -T /usr/bin/codesign
echo "created Showtell Local Signing"
