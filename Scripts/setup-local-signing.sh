#!/bin/bash
# One-time setup. The private key remains in the user's login keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
name='Call Recorder Local Development'
keychain="$HOME/Library/Keychains/login.keychain-db"
if SIGNING_IDENTITY="$name" ./Scripts/signing-identity.sh >/dev/null 2>&1; then
    echo "Already configured: $name"
    exit 0
fi
if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
    echo "A certificate named '$name' already exists but is not available for signing. Unlock the login keychain or repair that identity; this script will not replace it." >&2
    exit 1
fi
umask 077
temporary="$(mktemp -d "${TMPDIR:-/tmp}/call-recorder-signing.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
cat > "$temporary/certificate.cnf" <<'CONFIG'
[req]
prompt = no
distinguished_name = subject
x509_extensions = signing
[subject]
CN = Call Recorder Local Development
[signing]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
CONFIG
# The generated key and import bundle exist only in this private temp directory.
/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
    -config "$temporary/certificate.cnf" -keyout "$temporary/private.key" -out "$temporary/certificate.pem" 2>/dev/null
cat "$temporary/private.key" "$temporary/certificate.pem" > "$temporary/identity.pem"
# Only codesign receives preauthorized access to this new, non-extractable key.
security import "$temporary/identity.pem" -k "$keychain" -f pemseq -t agg -x -T /usr/bin/codesign
# User-domain trust for code signing only; no SSL or system-wide trust changes.
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$temporary/certificate.pem"
echo "Imported '$name' into the login keychain."
if ! SIGNING_IDENTITY="$name" ./Scripts/signing-identity.sh; then
    echo 'The certificate was imported but is not yet available as a valid code-signing identity. Inspect its code-signing trust in Keychain Access; do not create a replacement certificate.' >&2
    exit 1
fi
