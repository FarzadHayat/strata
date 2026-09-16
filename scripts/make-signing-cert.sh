#!/bin/bash
# Creates a persistent self-signed code-signing identity named "Strata Signing" in the login keychain.
# Why: TCC (Input Monitoring / Accessibility) keys its grants to the app's code-signing identity. An ad-hoc
# signature changes with every build, so permissions would be lost on each rebuild/update. A stable
# self-signed certificate gives a stable designated requirement instead. Run once per development machine.
set -euo pipefail
NAME="${1:-Strata Signing}"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "identity '$NAME' already exists"; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = Strata
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/openssl.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:strata -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:strata
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P strata -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# Trust it for code signing (user trust settings; macOS may ask for your password once).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" || \
  echo "warning: could not add trust settings automatically; open Keychain Access → '$NAME' → Trust → Code Signing: Always Trust"
echo "created identity '$NAME'"
security find-identity -v -p codesigning | grep "$NAME" || true
