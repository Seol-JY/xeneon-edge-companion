#!/bin/zsh
# Creates a local self-signed code-signing identity in the login keychain.
# Input Monitoring and Accessibility grants are tied to the signing identity, so a stable
# certificate keeps them across rebuilds (ad-hoc signatures change every build).
set -euo pipefail
NAME="${1:-EdgeCompanion Local Signing}"

if security find-certificate -c "$NAME" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
  echo "Certificate '$NAME' already exists."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS=$(openssl rand -hex 12)
# -legacy keeps the PKCS#12 readable by macOS `security` when openssl is 3.x.
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then LEGACY=(-legacy); else LEGACY=(); fi
openssl pkcs12 -export "${LEGACY[@]}" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout pass:"$PASS"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign
echo "Created '$NAME'."
