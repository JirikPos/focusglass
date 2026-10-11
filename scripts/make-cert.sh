#!/usr/bin/env bash
# Vytvoří v login klíčence vlastní podpisový certifikát „FocusGlass Dev“.
# Se stálým podpisem si macOS pamatuje udělená oprávnění (Kalendář, Automatizace)
# i po dalším sestavení. Smazat jde v aplikaci Klíčenka.
set -euo pipefail

NAME="FocusGlass Dev"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "✓ Certifikát „${NAME}“ už existuje"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cfg" <<CFG
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
CFG

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cfg" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass:focusglass
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P focusglass -T /usr/bin/codesign >/dev/null

echo "✓ Certifikát „${NAME}“ vytvořen"
