#!/usr/bin/env bash
set -euo pipefail

IDENTITY="Stillset Release"
REPO="qeude/Stillset"
BACKUP_DIR="${1:-$HOME/Stillset Release Certificate}"
ARCHIVE="$BACKUP_DIR/Stillset-Release.p12"
PASSWORD_FILE="$BACKUP_DIR/Stillset-Release.p12.password"
CERTIFICATE="$BACKUP_DIR/Stillset-Release.cer.pem"
KEYCHAIN="$(
  security default-keychain -d user \
    | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
)"

has_identity() {
  security find-identity -p codesigning -v | grep -F "\"$IDENTITY\"" >/dev/null
}

gh auth status >/dev/null 2>&1 || { echo "Run gh auth login first." >&2; exit 1; }
umask 077

if [[ ! -f "$ARCHIVE" ]]; then
  if has_identity; then
    echo "$IDENTITY is already in your keychain, but $ARCHIVE is missing." >&2
    echo "Export it from Keychain Access to that path, save its password in $PASSWORD_FILE, then rerun." >&2
    exit 1
  fi
  mkdir -p "$BACKUP_DIR"
  PRIVATE_KEY="$(mktemp "${TMPDIR:-/tmp}/stillset-release-key.XXXXXX")"
  trap 'rm -f "$PRIVATE_KEY"' EXIT
  /usr/bin/openssl rand -hex 24 > "$PASSWORD_FILE"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -subj "/CN=$IDENTITY/O=Stillset" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$PRIVATE_KEY" \
    -out "$CERTIFICATE" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -descert \
    -name "$IDENTITY" \
    -inkey "$PRIVATE_KEY" \
    -in "$CERTIFICATE" \
    -out "$ARCHIVE" \
    -passout "file:$PASSWORD_FILE"
  echo "Created $IDENTITY in $BACKUP_DIR"
fi

if ! has_identity; then
  security import "$ARCHIVE" -k "$KEYCHAIN" -f pkcs12 \
    -P "$(< "$PASSWORD_FILE")" -T /usr/bin/codesign >/dev/null
  echo "macOS will ask for your password to trust the certificate for code signing."
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERTIFICATE"
  has_identity || { echo "Failed to add $IDENTITY to $KEYCHAIN" >&2; exit 1; }
fi

FINGERPRINT="$(/usr/bin/openssl x509 -in "$CERTIFICATE" -outform DER | shasum -a 1 | cut -d ' ' -f 1)"
base64 -i "$ARCHIVE" | gh secret set STILLSET_RELEASE_P12_BASE64 --env release --repo "$REPO"
printf %s "$(< "$PASSWORD_FILE")" | gh secret set STILLSET_RELEASE_P12_PASSWORD --env release --repo "$REPO"
gh variable set STILLSET_RELEASE_CERT_SHA1 --repo "$REPO" --body "$FINGERPRINT"

echo
echo "Uploaded the signing secrets and fingerprint $FINGERPRINT to $REPO."
echo "Copy $BACKUP_DIR to your password manager or an offline backup, then delete the local folder."
