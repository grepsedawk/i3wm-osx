#!/usr/bin/env bash
# Create (once) a self-signed code-signing identity that gives i3wm-osx a
# stable cdhash across rebuilds, so macOS TCC remembers your Accessibility
# / Input Monitoring grant instead of re-prompting every time.
#
# Without this: ad-hoc signing → cdhash changes every rebuild → re-prompt.
# With this:    same identity   → cdhash stable              → grant sticks.
set -euo pipefail

CERT_NAME="${CERT_NAME:-i3wm-osx-codesign}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    echo "Code-signing identity '$CERT_NAME' already exists. Nothing to do."
    exit 0
fi

echo "Creating self-signed code-signing identity '$CERT_NAME'..."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $CERT_NAME
[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -x509 -days 7300 \
    -config "$WORK/cert.cnf" -extensions v3_req \
    -out "$WORK/cert.pem" 2>/dev/null

P12_PASS="i3wm-osx"
openssl pkcs12 -export \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/cert.p12" -password "pass:$P12_PASS" \
    -name "$CERT_NAME" -macalg sha256 2>/dev/null

security import "$WORK/cert.p12" \
    -P "$P12_PASS" \
    -k "$KEYCHAIN" \
    -A \
    -t cert -f pkcs12 \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

# Allow codesign to use the key without prompting each time.
# This requires the keychain password — macOS will prompt once.
echo
echo "macOS will now ask for your login keychain password to allow codesign"
echo "to use this identity without prompting on every build."
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" 2>/dev/null || \
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s "$KEYCHAIN"

echo
echo "Done. Identity:"
security find-identity -v -p codesigning | grep "$CERT_NAME" || true
echo
echo "Now run ./build-app.sh — it will pick this identity up automatically."
echo
echo "NOTE: The first time you launch the resulting app, macOS Gatekeeper"
echo "will warn it's from an unidentified developer. Right-click → Open,"
echo "then Open. After that it launches normally and TCC grants persist."
